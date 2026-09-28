//
//  AgentCoordinator.swift
//  leanring-buddy
//
//  Agent mode. Saying "agente, ..." (or "clicky agente, ...") hands the
//  request to a background agent instead of answering it directly:
//
//  - Quick Mac actions (reminder, calendar event, note, open app/link,
//    web search) are understood by the local model and run instantly on
//    the Mac. Free.
//  - Everything else (research, organizing, writing, building apps) goes
//    to Claude Code, which uses the user's Claude subscription.
//
//  Progress is listed in the menu bar panel, and the result is spoken
//  aloud and shown as a notification when the task finishes.
//

import Combine
import Foundation
import UserNotifications

enum AgentTaskKind {
    case quickMacAction
    case claudeCode
}

enum AgentTaskStatus {
    case running
    case completed
    case failed
    case cancelled
}

struct AgentTaskRecord: Identifiable {
    let id = UUID()
    let taskText: String
    let startedAt = Date()
    /// Nil while the request is still being classified.
    var kind: AgentTaskKind?
    var status: AgentTaskStatus = .running
    var logLines: [String] = []
    var summary: String?
}

@MainActor
final class AgentCoordinator: ObservableObject {
    @Published private(set) var tasks: [AgentTaskRecord] = []

    var runningTaskCount: Int {
        tasks.filter { $0.status == .running }.count
    }

    private let localVisionModelClient: LocalVisionModelClient
    /// Speaks a sentence aloud (provided by CompanionManager so the agent
    /// uses the same voice and waits for any answer already playing).
    private let speakAnnouncement: (String) -> Void
    private var claudeCodeRunnersByTaskID: [UUID: ClaudeCodeAgentRunner] = [:]
    private var hasRequestedNotificationPermission = false

    init(localVisionModelClient: LocalVisionModelClient, speakAnnouncement: @escaping (String) -> Void) {
        self.localVisionModelClient = localVisionModelClient
        self.speakAnnouncement = speakAnnouncement
    }

    // MARK: - Trigger detection

    /// Spoken prefixes that turn a request into an agent task. Apple's
    /// recognizer may spell "clicky" as "clique" or "click", so those
    /// variants are accepted too.
    private static let agentTriggerPrefixes = [
        "clicky agente", "clique agente", "click agente", "clicky agent",
        "ei agente", "ok agente", "oi agente",
        "agente", "agent"
    ]

    /// Returns the task text if the transcript starts with an agent trigger
    /// ("agente, organiza minhas notas" → "organiza minhas notas"), or nil
    /// for a normal question.
    static func extractAgentTaskText(from transcript: String) -> String? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let normalizedTranscript = trimmedTranscript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()

        for triggerPrefix in agentTriggerPrefixes {
            guard normalizedTranscript.hasPrefix(triggerPrefix) else { continue }

            // The trigger must be a whole word ("agentes de viagem" is not a trigger).
            let characterAfterTrigger = normalizedTranscript.dropFirst(triggerPrefix.count).first
            if let characterAfterTrigger, characterAfterTrigger.isLetter { continue }

            let taskText = String(trimmedTranscript.dropFirst(triggerPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return taskText.count >= 3 ? taskText : nil
        }
        return nil
    }

    // MARK: - Running tasks

    func startAgentTask(taskText: String) {
        let newTask = AgentTaskRecord(taskText: taskText)
        tasks.insert(newTask, at: 0)
        // Keep the panel list short.
        if tasks.count > 8 {
            tasks.removeLast(tasks.count - 8)
        }

        let taskID = newTask.id
        Task {
            await runAgentTask(taskID: taskID, taskText: taskText)
        }
    }

    func cancelTask(taskID: UUID) {
        claudeCodeRunnersByTaskID[taskID]?.cancel()
        updateTask(taskID) { task in
            if task.status == .running {
                task.status = .cancelled
                task.logLines.append("⏹️ Cancelado")
            }
        }
    }

    func clearFinishedTasks() {
        tasks.removeAll { $0.status != .running }
    }

    private func runAgentTask(taskID: UUID, taskText: String) async {
        appendLog(taskID, "🎙️ Pedido: \(taskText)")

        // Step 1: try to handle it as an instant Mac action with the local model.
        if await localVisionModelClient.isServerReachable() {
            do {
                let actionJSON = try await localVisionModelClient.completeJSON(
                    systemPrompt: Self.quickActionClassifierPrompt(),
                    userPrompt: taskText
                )
                let actionName = actionJSON["action"] as? String ?? "heavy"
                if actionName != "heavy" {
                    updateTask(taskID) { $0.kind = .quickMacAction }
                    appendLog(taskID, "⚡️ Ação rápida: \(actionName)")
                    try performQuickMacAction(actionName: actionName, actionJSON: actionJSON)
                    let confirmation = (actionJSON["confirmation"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "pronto."
                    finishTask(taskID, summary: confirmation, succeeded: true)
                    speakAnnouncement(confirmation)
                    return
                }
            } catch {
                // A failed quick action is retried by the heavy agent below,
                // which can reason about what went wrong.
                appendLog(taskID, "⚠️ Ação rápida falhou: \(error.localizedDescription)")
            }
        } else {
            appendLog(taskID, "ℹ️ Modelo local indisponível, usando Claude Code")
        }

        // Step 2: heavy task via Claude Code.
        guard isTaskStillRunning(taskID) else { return }
        updateTask(taskID) { $0.kind = .claudeCode }
        requestNotificationPermissionIfNeeded()
        speakAnnouncement("beleza, vou trabalhar nisso em segundo plano.")

        let claudeCodeRunner = ClaudeCodeAgentRunner()
        claudeCodeRunnersByTaskID[taskID] = claudeCodeRunner
        defer { claudeCodeRunnersByTaskID[taskID] = nil }

        do {
            let resultSummary = try await claudeCodeRunner.runTask(
                taskText: taskText,
                allowTerminalCommands: HybridSettings.shared.agentAllowsTerminalCommands,
                onLogLine: { [weak self] logLine in
                    self?.appendLog(taskID, logLine)
                }
            )
            guard isTaskStillRunning(taskID) else { return }
            finishTask(taskID, summary: resultSummary, succeeded: true)
            speakAnnouncement("tarefa pronta. " + resultSummary)
            postCompletionNotification(title: "Agente terminou", body: resultSummary)
        } catch is CancellationError {
            // Already marked as cancelled by cancelTask.
        } catch {
            guard isTaskStillRunning(taskID) else { return }
            finishTask(taskID, summary: error.localizedDescription, succeeded: false)
            speakAnnouncement("o agente teve um problema. os detalhes estão no painel.")
            postCompletionNotification(title: "Agente com problema", body: error.localizedDescription)
        }
    }

    private func performQuickMacAction(actionName: String, actionJSON: [String: Any]) throws {
        func stringValue(_ key: String) -> String {
            (actionJSON[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        switch actionName {
        case "create_reminder":
            try MacQuickActions.createReminder(
                title: stringValue("title"),
                dueDate: Self.parseLocalDateTime(stringValue("due"))
            )
        case "create_event":
            guard let startDate = Self.parseLocalDateTime(stringValue("start")) else {
                throw MacQuickActionError.invalidParameters("Data do evento não entendida")
            }
            let durationMinutes = (actionJSON["duration_minutes"] as? Int)
                ?? Int(stringValue("duration_minutes"))
                ?? 60
            try MacQuickActions.createCalendarEvent(
                title: stringValue("title"),
                startDate: startDate,
                durationMinutes: durationMinutes
            )
        case "create_note":
            try MacQuickActions.createNote(title: stringValue("title"), body: stringValue("body"))
        case "open_app":
            try MacQuickActions.openApplication(named: stringValue("name"))
        case "open_url":
            try MacQuickActions.openURL(stringValue("url"))
        case "web_search":
            try MacQuickActions.searchTheWeb(query: stringValue("query"))
        default:
            throw MacQuickActionError.invalidParameters("Ação desconhecida: \(actionName)")
        }
    }

    // MARK: - Prompt + parsing

    private static func quickActionClassifierPrompt() -> String {
        let currentDateFormatter = DateFormatter()
        currentDateFormatter.locale = Locale(identifier: "pt_BR")
        currentDateFormatter.dateFormat = "EEEE, yyyy-MM-dd'T'HH:mm"
        let currentDateDescription = currentDateFormatter.string(from: Date())

        return """
        Você converte um pedido falado em UMA ação para o Mac. Agora é \(currentDateDescription) (horário local).
        Responda SOMENTE com um objeto JSON, sem nenhum texto antes ou depois.

        Ações possíveis:
        {"action":"create_reminder","title":"...","due":"AAAA-MM-DDTHH:MM ou vazio","confirmation":"frase curta para falar"}
        {"action":"create_event","title":"...","start":"AAAA-MM-DDTHH:MM","duration_minutes":60,"confirmation":"..."}
        {"action":"create_note","title":"...","body":"...","confirmation":"..."}
        {"action":"open_app","name":"nome exato do app no macOS","confirmation":"..."}
        {"action":"open_url","url":"...","confirmation":"..."}
        {"action":"web_search","query":"...","confirmation":"..."}
        {"action":"heavy"}

        Use "heavy" para qualquer coisa que exija pesquisar e resumir informações, escrever textos longos, organizar várias notas ou arquivos, criar programas ou apps, ou mais de uma etapa. Na dúvida, use "heavy".
        A confirmação deve ser em português do Brasil, minúsculas, curta e natural, por exemplo "pronto, criei o lembrete para amanhã às nove".
        """
    }

    /// Parses "yyyy-MM-ddTHH:mm" (optionally with seconds) in the local time zone.
    private static func parseLocalDateTime(_ dateText: String) -> Date? {
        guard !dateText.isEmpty else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        for dateFormat in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            dateFormatter.dateFormat = dateFormat
            if let parsedDate = dateFormatter.date(from: dateText) {
                return parsedDate
            }
        }
        return nil
    }

    // MARK: - Task bookkeeping

    private func updateTask(_ taskID: UUID, _ mutate: (inout AgentTaskRecord) -> Void) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        mutate(&tasks[taskIndex])
    }

    private func appendLog(_ taskID: UUID, _ logLine: String) {
        print("🤖 Agent: \(logLine)")
        updateTask(taskID) { task in
            task.logLines.append(logLine)
            if task.logLines.count > 200 {
                task.logLines.removeFirst(task.logLines.count - 200)
            }
        }
    }

    private func isTaskStillRunning(_ taskID: UUID) -> Bool {
        tasks.first(where: { $0.id == taskID })?.status == .running
    }

    private func finishTask(_ taskID: UUID, summary: String, succeeded: Bool) {
        updateTask(taskID) { task in
            task.status = succeeded ? .completed : .failed
            task.summary = summary
        }
    }

    /// Asked when the first heavy task starts, so the permission prompt is
    /// answered long before the task finishes and posts its notification.
    private func requestNotificationPermissionIfNeeded() {
        guard !hasRequestedNotificationPermission else { return }
        hasRequestedNotificationPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postCompletionNotification(title: String, body: String) {
        let notificationCenter = UNUserNotificationCenter.current()
        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = title
        notificationContent.body = body
        let notificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notificationContent,
            trigger: nil
        )
        notificationCenter.add(notificationRequest)
    }
}
