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
        (audioPlayer?.isPlaying ?? false) || systemSpeechSynthesizer.isSpeaking
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        if systemSpeechSynthesizer.isSpeaking {
            systemSpeechSynthesizer.stopSpeaking(at: .immediate)
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
