//
//  LocalVisionModelClient.swift
//  leanring-buddy
//
//  Talks to a vision model running on this Mac through the OpenAI-compatible
//  chat completions endpoint. Ollama exposes it on http://127.0.0.1:11434/v1
//  out of the box; LM Studio and mlx_lm.server expose the same shape.
//
//  Ollama unloads the model after 5 idle minutes by default, so memory is
//  only used while you are actively asking questions.
//

import Foundation

@MainActor
final class LocalVisionModelClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        // The first request after the model was unloaded includes load time.
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    private var chatCompletionsURL: URL? {
        let baseURL = HybridSettings.shared.localModelServerURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return URL(string: "\(baseURL)/v1/chat/completions")
    }

    /// Returns true when the local model server answers. Used by the router
    /// to fall back to Claude when Ollama is not running.
    func isServerReachable() async -> Bool {
        let baseURL = HybridSettings.shared.localModelServerURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let modelsURL = URL(string: "\(baseURL)/v1/models") else { return false }
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Sends the screenshots + question to the local vision model and returns
    /// the full answer text.
    func analyzeImages(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> String {
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        var contentParts: [[String: Any]] = []
        for image in images {
            contentParts.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"]
            ])
            contentParts.append(["type": "text", "text": image.label])
        }
        contentParts.append(["type": "text", "text": userPrompt])
        messages.append(["role": "user", "content": contentParts])

        return try await sendChatCompletion(messages: messages, expectsJSONObject: false, maxTokens: 700)
    }

    /// Text-only request that must come back as a single JSON object. Used by
    /// the quick agent to turn a spoken command into a structured action.
    func completeJSON(systemPrompt: String, userPrompt: String) async throws -> [String: Any] {
        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]
        let responseText = try await sendChatCompletion(messages: messages, expectsJSONObject: true, maxTokens: 400)

        // Small models sometimes wrap JSON in prose or code fences. Pull out
        // the outermost {...} before parsing.
        guard let openingBraceIndex = responseText.firstIndex(of: "{"),
              let closingBraceIndex = responseText.lastIndex(of: "}"),
              openingBraceIndex < closingBraceIndex else {
            throw NSError(domain: "LocalVisionModel", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Local model did not return JSON: \(responseText)"])
        }
        let jsonText = String(responseText[openingBraceIndex...closingBraceIndex])
        guard let jsonData = jsonText.data(using: .utf8),
              let jsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw NSError(domain: "LocalVisionModel", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not parse local model JSON: \(jsonText)"])
        }
        return jsonObject
    }

    private func sendChatCompletion(
        messages: [[String: Any]],
        expectsJSONObject: Bool,
        maxTokens: Int
    ) async throws -> String {
        guard let chatCompletionsURL else {
            throw NSError(domain: "LocalVisionModel", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid local model server URL"])
        }

        var body: [String: Any] = [
            "model": HybridSettings.shared.localVisionModelName,
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": 0.3,
            "stream": false
        ]
        if expectsJSONObject {
            body["response_format"] = ["type": "json_object"]
        }

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let startTime = Date()
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "LocalVisionModel",
                          code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Local model error: \(errorBody)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "LocalVisionModel", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected local model response format"])
        }

        print("🖥️ Local model answered in \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
        return content
    }
}
