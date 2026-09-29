//
//  LocalSpeechOutput.swift
//  leanring-buddy
//
//  Free, on-device text-to-speech replacing ElevenLabs. Primary voice is
//  Kokoro (via the mlx-audio server, optimized for Apple Silicon). If that
//  server isn't running, it falls back to the built-in macOS voice so
//  Clicky never goes silent.
//
//  Exposes the same surface the ElevenLabs client had (speakText,
//  isPlaying, stopPlayback) so CompanionManager barely changes.
//

import AVFoundation
import Foundation

@MainActor
final class LocalSpeechOutput: NSObject {
    private let session: URLSession
    private var audioPlayer: AVAudioPlayer?
    private let systemSpeechSynthesizer = AVSpeechSynthesizer()

    // MARK: Sentence queue state
    //
    // Answers are spoken sentence by sentence while the model is still
    // writing: each sentence starts synthesizing as soon as it arrives, and
    // playback walks the queue in order. The first words are heard after one
    // short sentence instead of after the whole answer.

    private var queuedSentenceTexts: [String] = []
    private var queuedSentenceSynthesisTasks: [Task<Data?, Never>] = []
    private var isSentenceQueueInputFinished = false
    private var sentenceQueuePlaybackTask: Task<Void, Never>?
    /// Changes every time the queue is reset, so a stale playback task never
    /// clears the state of a newer one.
    private var sentenceQueueGeneration = UUID()
    private var onFirstQueuedSentenceStartedPlaying: (() -> Void)?

    override init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    /// Speaks `text`. Returns once playback has started (not finished),
    /// matching the old ElevenLabs behavior the pipeline relies on.
    func speakText(_ text: String) async throws {
        stopPlayback()

        do {
            let audioData = try await synthesizeWithKokoro(text)
            try Task.checkCancellation()
            let player = try AVAudioPlayer(data: audioData)
            self.audioPlayer = player
            player.play()
            print("🔊 Kokoro TTS: playing \(audioData.count / 1024)KB audio")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("⚠️ Kokoro TTS unavailable (\(error.localizedDescription)) — using macOS voice")
            try Task.checkCancellation()
            speakWithSystemVoice(text)
        }
    }

    var isPlaying: Bool {
        sentenceQueuePlaybackTask != nil
            || (audioPlayer?.isPlaying ?? false)
            || systemSpeechSynthesizer.isSpeaking
    }

    func stopPlayback() {
        sentenceQueuePlaybackTask?.cancel()
        sentenceQueuePlaybackTask = nil
        for synthesisTask in queuedSentenceSynthesisTasks {
            synthesisTask.cancel()
        }
        queuedSentenceSynthesisTasks.removeAll()
        queuedSentenceTexts.removeAll()
        isSentenceQueueInputFinished = true
        onFirstQueuedSentenceStartedPlaying = nil
        sentenceQueueGeneration = UUID()

        audioPlayer?.stop()
        audioPlayer = nil
        if systemSpeechSynthesizer.isSpeaking {
            systemSpeechSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - Sentence queue

    /// Starts an empty queue. Call `enqueueSentence` as sentences arrive and
    /// `finishSentenceQueue` when the answer is complete.
    func startSentenceQueue(onFirstSentenceStartedPlaying: @escaping () -> Void) {
        stopPlayback()
        isSentenceQueueInputFinished = false
        onFirstQueuedSentenceStartedPlaying = onFirstSentenceStartedPlaying
        let queueGeneration = sentenceQueueGeneration
        sentenceQueuePlaybackTask = Task {
            await playQueuedSentencesInOrder(queueGeneration: queueGeneration)
        }
    }

    func enqueueSentence(_ sentenceText: String) {
        let trimmedSentenceText = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentenceText.isEmpty, !isSentenceQueueInputFinished else { return }
        queuedSentenceTexts.append(trimmedSentenceText)
        // Synthesis starts right away, so the next sentence is usually ready
        // by the time the current one finishes playing.
        queuedSentenceSynthesisTasks.append(Task {
            try? await synthesizeWithKokoro(trimmedSentenceText)
        })
    }

    /// No more sentences will arrive; playback ends after the last one.
    func finishSentenceQueue() {
        isSentenceQueueInputFinished = true
    }

    private func playQueuedSentencesInOrder(queueGeneration: UUID) async {
        while !Task.isCancelled {
            if queuedSentenceSynthesisTasks.isEmpty {
                if isSentenceQueueInputFinished { break }
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }

            let synthesisTask = queuedSentenceSynthesisTasks.removeFirst()
            let sentenceText = queuedSentenceTexts.removeFirst()
            let synthesizedAudioData = await synthesisTask.value
            guard !Task.isCancelled else { return }

            if let synthesizedAudioData, let sentencePlayer = try? AVAudioPlayer(data: synthesizedAudioData) {
                audioPlayer = sentencePlayer
                sentencePlayer.play()
            } else {
                // Kokoro unavailable — the macOS voice keeps Clicky talking.
                let utterance = AVSpeechUtterance(string: sentenceText)
                utterance.voice = Self.bestSystemVoice(forLanguage: HybridSettings.shared.speechLocaleIdentifier)
                systemSpeechSynthesizer.speak(utterance)
            }

            if let firstSentenceCallback = onFirstQueuedSentenceStartedPlaying {
                onFirstQueuedSentenceStartedPlaying = nil
                firstSentenceCallback()
            }

            // Wait for this sentence to finish before starting the next.
            try? await Task.sleep(nanoseconds: 80_000_000)
            while (audioPlayer?.isPlaying ?? false) || systemSpeechSynthesizer.isSpeaking {
                try? await Task.sleep(nanoseconds: 30_000_000)
                if Task.isCancelled { return }
            }
        }

        if sentenceQueueGeneration == queueGeneration {
            sentenceQueuePlaybackTask = nil
        }
    }

    /// Speaks with the macOS voice only (used for short error messages that
    /// must work even when every server is down).
    func speakWithSystemVoice(_ text: String) {
        stopPlayback()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestSystemVoice(forLanguage: HybridSettings.shared.speechLocaleIdentifier)
        systemSpeechSynthesizer.speak(utterance)
    }

    // MARK: - Private

    private func synthesizeWithKokoro(_ text: String) async throws -> Data {
        let settings = HybridSettings.shared
        let baseURL = settings.kokoroServerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let speechURL = URL(string: "\(baseURL)/v1/audio/speech") else {
            throw NSError(domain: "KokoroTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Kokoro server URL"])
        }

        // Kokoro picks its phonemizer from the first letter of the voice
        // name: "p" = Brazilian Portuguese, "a" = American English, etc.
        let languageCode = String(settings.kokoroVoice.prefix(1))

        let body: [String: Any] = [
            "model": "mlx-community/Kokoro-82M-bf16",
            "input": text,
            "voice": settings.kokoroVoice,
            "lang_code": languageCode,
            "speed": 1.05,
            // WAV avoids needing ffmpeg on the server side.
            "response_format": "wav"
        ]

        var request = URLRequest(url: speechURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              !data.isEmpty else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "KokoroTTS",
                          code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Kokoro error: \(errorBody)"])
        }
        return data
    }

    /// Prefers premium/enhanced voices (downloadable in System Settings >
    /// Accessibility > Spoken Content) over the compact default.
    private static func bestSystemVoice(forLanguage languageIdentifier: String) -> AVSpeechSynthesisVoice? {
        let matchingVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.lowercased() == languageIdentifier.lowercased()
        }
        if let premiumVoice = matchingVoices.first(where: { $0.quality == .premium }) {
            return premiumVoice
        }
        if let enhancedVoice = matchingVoices.first(where: { $0.quality == .enhanced }) {
            return enhancedVoice
        }
        return matchingVoices.first ?? AVSpeechSynthesisVoice(language: languageIdentifier)
    }
}

/// Splits a streaming answer into complete sentences as it grows, so each
/// sentence can be spoken as soon as it is written. Everything from the
/// first "[" on is held back: that is where the [ELEMENT]/[POINT] pointing
/// tag starts, and it must never be read aloud.
@MainActor
final class StreamingSentenceExtractor {
    /// Characters of the speakable text already handed out as sentences.
    private var consumedCharacterCount = 0

    /// All sentences handed out so far, joined — shown in the text bubble
    /// while the rest of the answer is still being written.
    private(set) var handedOutText = ""

    /// Sentences shorter than this are merged with the next one, so the
    /// voice doesn't stutter through "ok." "então." as separate clips.
    private let minimumSentenceLength = 12

    func extractNewCompleteSentences(from accumulatedText: String) -> [String] {
        let speakableCharacters = Array(Self.textBeforePointingTag(accumulatedText))
        guard consumedCharacterCount < speakableCharacters.count else { return [] }

        var completeSentences: [String] = []
        var sentenceStartIndex = consumedCharacterCount
        var characterIndex = consumedCharacterCount

        while characterIndex < speakableCharacters.count {
            let character = speakableCharacters[characterIndex]
            let isSentenceEndingCharacter = ".!?…".contains(character) || character == "\n"
            let nextCharacterIndex = characterIndex + 1
            // Require whitespace after the punctuation so "3.5" or a still-
            // streaming "..." don't split a sentence early.
            let isFollowedByWhitespace = nextCharacterIndex < speakableCharacters.count
                && speakableCharacters[nextCharacterIndex].isWhitespace
            let currentSentenceLength = characterIndex - sentenceStartIndex + 1

            if isSentenceEndingCharacter && isFollowedByWhitespace && currentSentenceLength >= minimumSentenceLength {
                let sentenceText = String(speakableCharacters[sentenceStartIndex...characterIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentenceText.isEmpty {
                    completeSentences.append(sentenceText)
                }
                sentenceStartIndex = nextCharacterIndex
            }
            characterIndex += 1
        }

        consumedCharacterCount = sentenceStartIndex
        for sentenceText in completeSentences {
            handedOutText += (handedOutText.isEmpty ? "" : " ") + sentenceText
        }
        return completeSentences
    }

    /// Returns whatever speakable text has not been handed out yet. Called
    /// once the full answer has arrived.
    func extractRemainingText(from fullText: String) -> String {
        let speakableCharacters = Array(Self.textBeforePointingTag(fullText))
        guard consumedCharacterCount < speakableCharacters.count else { return "" }
        let remainingText = String(speakableCharacters[consumedCharacterCount...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        consumedCharacterCount = speakableCharacters.count
        return remainingText
    }

    private static func textBeforePointingTag(_ text: String) -> String {
        guard let tagStartIndex = text.firstIndex(of: "[") else { return text }
        return String(text[..<tagStartIndex])
    }
}
