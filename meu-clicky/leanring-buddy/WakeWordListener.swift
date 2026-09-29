//
//  WakeWordListener.swift
//  leanring-buddy
//
//  Hands-free mode: listens for "ei Clicky" / "oi Clicky" with Apple's
//  on-device speech recognizer (nothing leaves the Mac), then captures what
//  the user says next and hands it over as if they had used push-to-talk.
//
//  The recognizer usually spells "Clicky" as "clique", "click" or "cliquei",
//  so those count too, but only right after a greeting ("ei", "oi", "hey"),
//  otherwise every "clique aqui" would wake it.
//

import AVFoundation
import Foundation
import Speech

@MainActor
final class WakeWordListener {
    /// Called when the wake phrase is heard (show the listening cursor).
    var onWakePhraseDetected: (() -> Void)?
    /// Called with the spoken command that followed the wake phrase.
    var onCommandCaptured: ((String) -> Void)?
    /// Called when the wake phrase was heard but nothing followed.
    var onCommandCaptureAbandoned: (() -> Void)?
    /// Asked several times a second; listening pauses whenever it is false
    /// (push-to-talk in use, Clicky talking, setting off).
    var shouldBeListening: (() -> Bool)?

    private(set) var isCapturingCommand = false

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isAudioEngineRunning = false
    private var supervisionTimer: Timer?
    private var recognitionSessionStartedAt = Date()

    private var latestTranscript = ""
    private var latestTranscriptChangedAt = Date()
    private var wakePhraseDetectedAt = Date()
    /// Character offset in `latestTranscript` where the command starts.
    private var commandStartCharacterOffset = 0

    /// Silence after the command that means "I'm done talking".
    private let endOfCommandSilenceSeconds: TimeInterval = 1.3
    /// Give up if nothing is said after the wake phrase.
    private let emptyCommandTimeoutSeconds: TimeInterval = 5
    private let maximumCommandSeconds: TimeInterval = 15
    /// Recognition sessions are time-limited; recycle idle ones.
    private let idleSessionRecycleSeconds: TimeInterval = 50

    private static let wakePhrasePattern =
        #"\b(ei|ey|hey|oi|olá|ola|e aí|e ai)[,!.]?\s+(clicky|clique|cliquei|click|clic|klick|kliki|cliki|clik)\b[,!.]?"#

    func startSupervising() {
        supervisionTimer?.invalidate()
        supervisionTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.superviseListening()
            }
        }
    }

    /// Releases the microphone and recognizer right away. Push-to-talk calls
    /// this on key-down: waiting for the next supervision tick left both
    /// recognizers running together, and push-to-talk got "No speech detected".
    func pauseListeningNow() {
        stopListening()
    }

    func stopEverything() {
        supervisionTimer?.invalidate()
        supervisionTimer = nil
        stopListening()
    }

    // MARK: - Supervision

    private func superviseListening() {
        let wantsToListen = shouldBeListening?() ?? false

        if wantsToListen && !isAudioEngineRunning {
            startListening()
        } else if !wantsToListen && isAudioEngineRunning && !isCapturingCommand {
            stopListening()
        }

        guard isAudioEngineRunning else { return }

        if isCapturingCommand {
            let secondsSinceWake = Date().timeIntervalSince(wakePhraseDetectedAt)
            let secondsOfSilence = Date().timeIntervalSince(latestTranscriptChangedAt)
            let commandText = currentCommandText()

            if !commandText.isEmpty && (secondsOfSilence >= endOfCommandSilenceSeconds || secondsSinceWake >= maximumCommandSeconds) {
                finishCommandCapture(commandText: commandText)
            } else if commandText.isEmpty && secondsSinceWake >= emptyCommandTimeoutSeconds {
                isCapturingCommand = false
                onCommandCaptureAbandoned?()
                restartRecognitionSession()
            }
        } else if Date().timeIntervalSince(recognitionSessionStartedAt) >= idleSessionRecycleSeconds {
            restartRecognitionSession()
        }
    }

    // MARK: - Audio + recognition

    private func startListening() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { return }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isAudioEngineRunning = true
            startRecognitionSession()
            print("👂 Wake word: listening for \"ei Clicky\"")
        } catch {
            inputNode.removeTap(onBus: 0)
            print("⚠️ Wake word: couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    private func stopListening() {
        endRecognitionSession()
        if isAudioEngineRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            isAudioEngineRunning = false
        }
        isCapturingCommand = false
    }

    private func startRecognitionSession() {
        let preferredLocaleIdentifier = UserDefaults.standard.string(forKey: "hybridSpeechLocaleIdentifier") ?? "pt-BR"
        guard let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: preferredLocaleIdentifier)),
              speechRecognizer.isAvailable else {
            return
        }
        // Always-on listening must stay on the Mac: never stream the room's
        // audio to a server. Without the on-device model, hands-free is off.
        guard speechRecognizer.supportsOnDeviceRecognition else {
            print("⚠️ Wake word: on-device recognition for \(preferredLocaleIdentifier) isn't installed (System Settings > Keyboard > Dictation)")
            return
        }

        let newRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        newRecognitionRequest.shouldReportPartialResults = true
        newRecognitionRequest.taskHint = .search
        newRecognitionRequest.requiresOnDeviceRecognition = true
        newRecognitionRequest.contextualStrings = ["Clicky", "ei Clicky", "oi Clicky"]

        recognitionRequest = newRecognitionRequest
        latestTranscript = ""
        commandStartCharacterOffset = 0
        recognitionSessionStartedAt = Date()

        recognitionTask = speechRecognizer.recognitionTask(with: newRecognitionRequest) { [weak self] result, error in
            let transcriptText = result?.bestTranscription.formattedString
            let isFinalResult = result?.isFinal ?? false
            let didFail = error != nil
            Task { @MainActor in
                self?.handleRecognitionUpdate(
                    transcriptText: transcriptText,
                    isFinalResult: isFinalResult,
                    didFail: didFail
                )
            }
        }
    }

    private func endRecognitionSession() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func restartRecognitionSession() {
        endRecognitionSession()
        if isAudioEngineRunning {
            startRecognitionSession()
        }
    }

    private func handleRecognitionUpdate(transcriptText: String?, isFinalResult: Bool, didFail: Bool) {
        if let transcriptText, transcriptText != latestTranscript {
            latestTranscript = transcriptText
            latestTranscriptChangedAt = Date()

            if !isCapturingCommand {
                detectWakePhrase(in: transcriptText)
            }
        }

        // The recognizer ended this session (silence, error or time limit).
        if isFinalResult || didFail {
            if isCapturingCommand {
                let commandText = currentCommandText()
                if !commandText.isEmpty {
                    finishCommandCapture(commandText: commandText)
                    return
                }
            }
            if isAudioEngineRunning {
                restartRecognitionSession()
            }
        }
    }

    private func detectWakePhrase(in transcriptText: String) {
        let normalizedTranscript = transcriptText.lowercased()
        guard let wakeRegex = try? NSRegularExpression(pattern: Self.wakePhrasePattern, options: [.caseInsensitive]),
              let wakeMatch = wakeRegex.matches(
                in: normalizedTranscript,
                range: NSRange(normalizedTranscript.startIndex..., in: normalizedTranscript)
              ).last,
              let wakeMatchRange = Range(wakeMatch.range, in: normalizedTranscript) else {
            return
        }

        isCapturingCommand = true
        wakePhraseDetectedAt = Date()
        latestTranscriptChangedAt = Date()
        commandStartCharacterOffset = normalizedTranscript.distance(
            from: normalizedTranscript.startIndex,
            to: wakeMatchRange.upperBound
        )
        print("👂 Wake word detected")
        onWakePhraseDetected?()
    }

    private func currentCommandText() -> String {
        guard commandStartCharacterOffset < latestTranscript.count else { return "" }
        let commandStartIndex = latestTranscript.index(latestTranscript.startIndex, offsetBy: commandStartCharacterOffset)
        return String(latestTranscript[commandStartIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func finishCommandCapture(commandText: String) {
        isCapturingCommand = false
        print("👂 Wake command: \(commandText)")
        // Start a fresh session so the old command never re-triggers.
        restartRecognitionSession()
        onCommandCaptured?(commandText)
    }
}
