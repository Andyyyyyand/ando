//
//  ClaudeCodeAgentRunner.swift
//  leanring-buddy
//
//  Runs heavy agent tasks (research, organizing files, building small apps)
//  through the Claude Code CLI installed on this Mac. Claude Code signs in
//  with the user's existing Claude subscription, so these tasks don't need
//  the paid API key.
//
//  The agent works inside ~/ClickyAgente. By default it may read, write,
//  edit files and use the web, but not run terminal commands; the user can
//  opt in to terminal commands in the panel.
//

import Foundation

@MainActor
final class ClaudeCodeAgentRunner {
    /// Folder the agent works in. Created on first use.
    static let agentWorkingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ClickyAgente", isDirectory: true)

    private var runningProcess: Process?

    /// Finds the `claude` binary. Apps launched from Finder don't inherit the
    /// shell PATH, so common install locations are checked first, then a
    /// login shell is asked as a last resort.
    static func locateClaudeCodeExecutable() -> URL? {
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = [
            "\(homeDirectoryPath)/.local/bin/claude",
            "\(homeDirectoryPath)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        for candidatePath in candidatePaths where FileManager.default.isExecutableFile(atPath: candidatePath) {
            return URL(fileURLWithPath: candidatePath)
        }

        let shellLookupProcess = Process()
        shellLookupProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shellLookupProcess.arguments = ["-lc", "command -v claude"]
        let outputPipe = Pipe()
        shellLookupProcess.standardOutput = outputPipe
        shellLookupProcess.standardError = Pipe()
        do {
            try shellLookupProcess.run()
            shellLookupProcess.waitUntilExit()
        } catch {
            return nil
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let resolvedPath = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolvedPath.isEmpty, FileManager.default.isExecutableFile(atPath: resolvedPath) else {
            return nil
        }
        return URL(fileURLWithPath: resolvedPath)
    }

    /// Runs one task to completion. `onLogLine` receives human-readable
    /// progress lines (tool calls, messages) as they happen. Returns the
    /// agent's final summary.
    func runTask(
        taskText: String,
        allowTerminalCommands: Bool,
        allowConnectedIntegrations: Bool,
        onLogLine: @escaping (String) -> Void
    ) async throws -> String {
        guard let claudeExecutableURL = Self.locateClaudeCodeExecutable() else {
            throw NSError(domain: "ClaudeCodeAgent", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Claude Code não está instalado. Instale com: curl -fsSL https://claude.ai/install.sh | bash"
            ])
        }

        try FileManager.default.createDirectory(at: Self.agentWorkingDirectory, withIntermediateDirectories: true)

        var allowedTools = ["Read", "Write", "Edit", "Glob", "Grep", "WebSearch", "WebFetch", "TodoWrite"]
        if allowTerminalCommands {
            allowedTools.append("Bash")
        }

        // Accounts connected at claude.ai/customize/connectors (Gmail,
        // Google Calendar, Notion, Linear...) show up in Claude Code as MCP
        // servers. Allow the tools of every connected one.
        if allowConnectedIntegrations {
            let connectedIntegrationNames = await Self.connectedIntegrationServerNames(
                claudeExecutableURL: claudeExecutableURL
            )
            if connectedIntegrationNames.isEmpty {
                onLogLine("ℹ️ Nenhuma integração conectada (conecte em claude.ai/customize/connectors)")
            } else {
                onLogLine("🔌 Integrações: " + connectedIntegrationNames.joined(separator: ", "))
                for integrationName in connectedIntegrationNames {
                    allowedTools.append("mcp__\(Self.toolPrefixName(forServerName: integrationName))__*")
                }
            }
        }

        let agentPrompt = """
        Você é o agente do Clicky, um assistente de voz no Mac do usuário. O usuário pediu por voz:

        "\(taskText)"

        Regras:
        - Trabalhe dentro da pasta atual (\(Self.agentWorkingDirectory.path)). Salve ali qualquer arquivo que criar.
        - Não apague nem sobrescreva arquivos fora dessa pasta.
        - Se precisar de algo que suas ferramentas não permitem, explique no resumo final o que faltou.
        - Você pode usar as integrações conectadas (Gmail, Google Agenda, Notion, Linear e outras) quando o pedido envolver essas contas.
        - E-mails: crie um RASCUNHO, a menos que o usuário tenha dito explicitamente para enviar. Nunca apague e-mails, eventos ou páginas.
        - Termine com um resumo curto, em português do Brasil, de uma ou duas frases, escrito para ser falado em voz alta: sem markdown, sem listas, sem links.
        """

        let agentProcess = Process()
        agentProcess.executableURL = claudeExecutableURL
        agentProcess.arguments = [
            "-p", agentPrompt,
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "acceptEdits",
            "--allowedTools", allowedTools.joined(separator: ",")
        ]
        agentProcess.currentDirectoryURL = Self.agentWorkingDirectory

        agentProcess.environment = Self.makeAgentProcessEnvironment()

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        agentProcess.standardOutput = standardOutputPipe
        agentProcess.standardError = standardErrorPipe
        // Without an explicit empty stdin, `claude -p` may wait for piped input.
        agentProcess.standardInput = FileHandle.nullDevice

        try agentProcess.run()
        runningProcess = agentProcess
        onLogLine("▶️ Claude Code iniciado em \(Self.agentWorkingDirectory.path)")

        var finalResultText: String?
        var finalResultIsError = false

        // stream-json emits one JSON object per line.
        for try await outputLine in standardOutputPipe.fileHandleForReading.bytes.lines {
            guard let lineData = outputLine.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let eventType = event["type"] as? String else {
                continue
            }

            if eventType == "assistant",
               let message = event["message"] as? [String: Any],
               let contentBlocks = message["content"] as? [[String: Any]] {
                for contentBlock in contentBlocks {
                    let blockType = contentBlock["type"] as? String
                    if blockType == "text", let text = contentBlock["text"] as? String, !text.isEmpty {
                        onLogLine("💬 " + String(text.prefix(300)))
                    } else if blockType == "tool_use", let toolName = contentBlock["name"] as? String {
                        onLogLine("🔧 \(toolName) " + Self.shortToolInputDescription(contentBlock["input"]))
                    }
                }
            }

            if eventType == "result" {
                finalResultText = event["result"] as? String
                finalResultIsError = (event["is_error"] as? Bool) ?? false
                if let totalCostUSD = event["total_cost_usd"] as? Double {
                    onLogLine(String(format: "✅ Terminado (custo equivalente: US$ %.2f, coberto pela assinatura)", totalCostUSD))
                }
            }
        }

        agentProcess.waitUntilExit()
        runningProcess = nil

        if agentProcess.terminationReason == .uncaughtSignal {
            throw CancellationError()
        }

        if finalResultText == nil || agentProcess.terminationStatus != 0 {
            let errorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !errorText.isEmpty {
                onLogLine("⚠️ " + String(errorText.prefix(500)))
            }
        }

        guard let finalResultText, !finalResultIsError else {
            throw NSError(domain: "ClaudeCodeAgent", code: Int(agentProcess.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: finalResultText ?? "O Claude Code terminou sem resultado. Rode 'claude' no Terminal uma vez para fazer login."
            ])
        }
        return finalResultText
    }

    func cancel() {
        runningProcess?.terminate()
    }

    /// GUI apps don't inherit the shell PATH; add the usual install folders.
    private static func makeAgentProcessEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPathEntries = ["\(homeDirectoryPath)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extraPathEntries + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return environment
    }

    /// Asks `claude mcp list` which MCP servers are connected. Lines look like
    /// `claude.ai Gmail: https://… - ✓ Connected`. Returns the server names.
    private static func connectedIntegrationServerNames(claudeExecutableURL: URL) async -> [String] {
        let listProcess = Process()
        listProcess.executableURL = claudeExecutableURL
        listProcess.arguments = ["mcp", "list"]
        listProcess.environment = makeAgentProcessEnvironment()
        listProcess.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        listProcess.standardOutput = outputPipe
        listProcess.standardError = Pipe()

        do {
            try listProcess.run()
        } catch {
            return []
        }

        // Health checks can hang on a broken server; don't wait forever.
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if listProcess.isRunning {
                listProcess.terminate()
            }
        }
        defer { timeoutTask.cancel() }

        var connectedServerNames: [String] = []
        do {
            for try await outputLine in outputPipe.fileHandleForReading.bytes.lines {
                guard outputLine.contains("✓") || outputLine.localizedCaseInsensitiveContains("connected"),
                      !outputLine.localizedCaseInsensitiveContains("not connected"),
                      !outputLine.localizedCaseInsensitiveContains("failed"),
                      let nameSeparatorRange = outputLine.range(of: ": ") else {
                    continue
                }
                let serverName = String(outputLine[..<nameSeparatorRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if !serverName.isEmpty {
                    connectedServerNames.append(serverName)
                }
            }
        } catch {
            return connectedServerNames
        }
        return connectedServerNames
    }

    /// Claude Code turns a server name like "claude.ai Gmail" into the tool
    /// prefix "claude_ai_Gmail" (anything but letters, digits, "_" and "-"
    /// becomes "_").
    private static func toolPrefixName(forServerName serverName: String) -> String {
        String(serverName.map { character -> Character in
            let isAllowedCharacter = character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
            return isAllowedCharacter ? character : "_"
        })
    }

    private static func shortToolInputDescription(_ toolInput: Any?) -> String {
        guard let toolInputDictionary = toolInput as? [String: Any] else { return "" }
        let interestingKeys = ["file_path", "path", "pattern", "query", "url", "command", "description"]
        for interestingKey in interestingKeys {
            if let value = toolInputDictionary[interestingKey] as? String {
                return String(value.prefix(120))
            }
        }
        return ""
    }
}
