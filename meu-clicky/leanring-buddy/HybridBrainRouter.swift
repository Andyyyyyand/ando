//
//  HybridBrainRouter.swift
//  leanring-buddy
//
//  Decides, per question, whether the free local model or Claude answers.
//
//  In automatic mode:
//  1. Saying "usa o claude" / "pergunta difícil" forces Claude.
//  2. Questions that clearly need reasoning (explain, code, errors,
//     summarize, compare, write...), ask where something is on screen
//     ("onde fica", "cadê", "mostra") or to act on it ("toca", "clica",
//     "abre"), or are long go to Claude.
//  3. Everything else goes to the local model, which may still hand the
//     question to Claude by replying [ESCALAR] when it isn't confident.
//
//  Without a Claude API key everything stays local; without a running
//  local model everything goes to Claude.
//

import Foundation

enum BrainChoice {
    case localModel
    case claude
}

@MainActor
enum HybridBrainRouter {

    /// Marker the local model replies with when a question is beyond it.
    static let localEscalationMarker = "[ESCALAR]"

    private static let explicitClaudeRequestPhrases = [
        "usa o claude", "use o claude", "usar o claude", "pergunta o claude", "pergunta ao claude",
        "pergunta dificil", "modo inteligente", "pensa bem", "capricha"
    ]

    private static let explicitLocalRequestPhrases = [
        "responde rapido", "resposta rapida", "modo rapido"
    ]

    /// Word stems that signal a question needs real reasoning.
    private static let hardQuestionStems = [
        "explica", "explique", "detalh", "por que", "por quê", "porque isso", "como funciona",
        "codigo", "código", "programa", "funcao", "função", "bug", "erro", "error", "debug",
        "analis", "resum", "compar", "diferenca", "diferença", "vantage",
        "escrev", "redij", "redig", "reescrev", "traduz", "revis", "corrig",
        "calcul", "formula", "fórmula", "planilha", "estrategi", "estratégi",
        "passo a passo", "otimiz", "melhor forma", "melhor jeito", "aprend", "ensina",
        "explain", "why", "code", "summar", "compare", "write", "fix"
    ]

    /// Whole words that mean "show me where something is on screen" or "do
    /// something on screen". The small local vision model misses real screen
    /// positions and picks the wrong element, so these go to Claude. Matched
    /// as whole words so "responde" doesn't count as "onde".
    private static let pointingQuestionWords: Set<String> = [
        "onde", "aonde", "cade", "aponta", "aponte", "mostra", "mostre",
        "clico", "clica", "clique", "clicar", "aperta", "aperte", "apertar",
        "toca", "toque", "tocar", "abre", "abra", "abrir", "fecha", "feche", "fechar",
        "seleciona", "selecione", "arrasta", "arraste",
        "where", "click", "press", "open", "play"
    ]

    /// Transcripts longer than this are treated as complex requests.
    private static let longQuestionWordCount = 28

    static func chooseBrain(
        forTranscript transcript: String,
        brainMode: HybridBrainMode,
        hasClaudeAPIKey: Bool,
        isLocalModelReachable: Bool
    ) -> BrainChoice {
        if !hasClaudeAPIKey { return .localModel }
        if !isLocalModelReachable { return .claude }

        switch brainMode {
        case .localOnly:
            return .localModel
        case .claudeOnly:
            return .claude
        case .automatic:
            break
        }

        let normalizedTranscript = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()

        if explicitLocalRequestPhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return .localModel
        }
        if explicitClaudeRequestPhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return .claude
        }

        let wordCount = normalizedTranscript.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount > longQuestionWordCount {
            return .claude
        }

        let transcriptWords = normalizedTranscript.split(whereSeparator: { !$0.isLetter }).map(String.init)
        if transcriptWords.contains(where: { pointingQuestionWords.contains($0) }) {
            return .claude
        }

        let foldedHardQuestionStems = hardQuestionStems.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
        }
        if foldedHardQuestionStems.contains(where: { normalizedTranscript.contains($0) }) {
            return .claude
        }

        return .localModel
    }

    /// True when the local model's answer means "please ask Claude instead".
    static func localAnswerRequestsEscalation(_ localAnswer: String) -> Bool {
        localAnswer.contains(localEscalationMarker)
    }
}
