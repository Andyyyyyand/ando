//
//  HybridBrainRouter.swift
//  leanring-buddy
//
//  Decides, per question, whether the free local model or Claude answers.
//
//  In automatic mode:
//  1. Saying "usa o claude" / "pergunta difícil" forces Claude.
//  2. Questions that clearly need reasoning (explain, code, errors,
//     summarize, compare, write...) or are long go to Claude.
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
