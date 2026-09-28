//
//  HybridControlsPanelSection.swift
//  leanring-buddy
//
//  Panel controls for the hybrid build: brain mode (Auto/Local/Claude),
//  Claude model, API key, local server status, voice, and the list of
//  background agent tasks.
//

import AppKit
import SwiftUI

struct HybridControlsPanelSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var hybridSettings: HybridSettings
    @ObservedObject var agentCoordinator: AgentCoordinator

    @State private var isShowingAdvancedSettings = false
    @State private var claudeAPIKeyInput = ""
    @State private var isLocalModelOnline: Bool?
    @State private var isKokoroVoiceOnline: Bool?
    @State private var isClaudeCodeInstalled: Bool?
    @State private var expandedAgentTaskID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            brainModeRow

            if hybridSettings.brainMode != .localOnly {
                claudeModelRow
            }

            if let lastAnsweringBrainDescription = companionManager.lastAnsweringBrainDescription {
                Text("Última resposta: \(lastAnsweringBrainDescription)")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if !agentCoordinator.tasks.isEmpty {
                agentTasksSection
            }

            advancedSettingsToggle

            if isShowingAdvancedSettings {
                advancedSettingsContent
            }
        }
        .onAppear {
            refreshServiceStatus()
        }
    }

    // MARK: - Brain + Model

    private var brainModeRow: some View {
        HStack {
            Text("Cérebro")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            segmentedButtonGroup {
                ForEach(HybridBrainMode.allCases, id: \.rawValue) { brainMode in
                    segmentButton(
                        label: brainMode.displayName,
                        isSelected: hybridSettings.brainMode == brainMode
                    ) {
                        hybridSettings.brainMode = brainMode
                        NotificationCenter.default.post(name: .clickyPanelContentSizeChanged, object: nil)
                    }
                }
            }
        }
    }

    private var claudeModelRow: some View {
        HStack {
            Text("Modelo Claude")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            segmentedButtonGroup {
                ForEach(HybridSettings.claudeModelOptions) { modelOption in
                    segmentButton(
                        label: modelOption.label,
                        isSelected: hybridSettings.claudeModel == modelOption.value
                    ) {
                        hybridSettings.claudeModel = modelOption.value
                    }
                }
            }
        }
    }

    // MARK: - Agents

    private var agentTasksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Agentes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Limpar") {
                    agentCoordinator.clearFinishedTasks()
                    NotificationCenter.default.post(name: .clickyPanelContentSizeChanged, object: nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .pointerCursor()
            }

            ForEach(agentCoordinator.tasks) { agentTask in
                agentTaskRow(agentTask)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func agentTaskRow(_ agentTask: AgentTaskRecord) -> some View {
        let isExpanded = expandedAgentTaskID == agentTask.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text(agentStatusSymbol(agentTask))
                    .font(.system(size: 11))

                VStack(alignment: .leading, spacing: 2) {
                    Text(agentTask.taskText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(isExpanded ? nil : 2)

                    if let latestDetail = agentTask.summary ?? agentTask.logLines.last {
                        Text(latestDetail)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(isExpanded ? nil : 2)
                    }
                }

                Spacer(minLength: 4)

                if agentTask.status == .running {
                    Button(action: { agentCoordinator.cancelTask(taskID: agentTask.id) }) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Cancelar")
                }

                Button(action: {
                    expandedAgentTaskID = isExpanded ? nil : agentTask.id
                    NotificationCenter.default.post(name: .clickyPanelContentSizeChanged, object: nil)
                }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Ver o que o agente fez")
            }

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(agentTask.logLines.enumerated()), id: \.offset) { _, logLine in
                            Text(logLine)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(DS.Colors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(height: 140)
            }
        }
    }

    private func agentStatusSymbol(_ agentTask: AgentTaskRecord) -> String {
        switch agentTask.status {
        case .running: return agentTask.kind == .quickMacAction ? "⚡️" : "⏳"
        case .completed: return "✅"
        case .failed: return "⚠️"
        case .cancelled: return "⏹️"
        }
    }

    // MARK: - Advanced Settings

    private var advancedSettingsToggle: some View {
        Button(action: {
            isShowingAdvancedSettings.toggle()
            if isShowingAdvancedSettings {
                refreshServiceStatus()
            }
            NotificationCenter.default.post(name: .clickyPanelContentSizeChanged, object: nil)
        }) {
            HStack(spacing: 6) {
                Image(systemName: isShowingAdvancedSettings ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                Text("Configurações")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                serviceStatusDots
            }
            .foregroundColor(DS.Colors.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// Three dots summarizing the local services: model, voice, Claude Code.
    private var serviceStatusDots: some View {
        HStack(spacing: 4) {
            statusDot(isOnline: isLocalModelOnline)
            statusDot(isOnline: isKokoroVoiceOnline)
            statusDot(isOnline: isClaudeCodeInstalled)
        }
        .help("Modelo local · Voz Kokoro · Claude Code")
    }

    private var advancedSettingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Claude API key
            VStack(alignment: .leading, spacing: 4) {
                Text(hybridSettings.hasClaudeAPIKey
                     ? "Chave da API do Claude: salva ✓"
                     : "Chave da API do Claude (opcional — sem ela, tudo roda local)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                HStack(spacing: 6) {
                    SecureField(hybridSettings.hasClaudeAPIKey ? "Trocar chave…" : "sk-ant-…", text: $claudeAPIKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )

                    smallActionButton(label: "Salvar") {
                        hybridSettings.saveClaudeAPIKey(claudeAPIKeyInput)
                        claudeAPIKeyInput = ""
                    }

                    if hybridSettings.hasClaudeAPIKey {
                        smallActionButton(label: "Apagar") {
                            hybridSettings.saveClaudeAPIKey("")
                        }
                    }
                }
            }

            // Service status
            VStack(alignment: .leading, spacing: 3) {
                serviceStatusRow(name: "Modelo local (\(hybridSettings.localVisionModelName))", isOnline: isLocalModelOnline,
                                 offlineHint: "abra o Ollama")
                serviceStatusRow(name: "Voz Kokoro", isOnline: isKokoroVoiceOnline,
                                 offlineHint: "usando a voz do macOS")
                serviceStatusRow(name: "Claude Code (agente)", isOnline: isClaudeCodeInstalled,
                                 offlineHint: "não instalado")
                smallActionButton(label: "Verificar de novo") {
                    refreshServiceStatus()
                }
            }

            // Voice
            HStack {
                Text("Voz")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                segmentedButtonGroup {
                    ForEach(HybridSettings.kokoroVoiceOptions) { voiceOption in
                        segmentButton(
                            label: voiceOption.label,
                            isSelected: hybridSettings.kokoroVoice == voiceOption.value
                        ) {
                            hybridSettings.kokoroVoice = voiceOption.value
                        }
                    }
                }
            }

            // Agent options
            HStack {
                Text("Agente pode usar o Terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Toggle("", isOn: $hybridSettings.agentAllowsTerminalCommands)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
                    .scaleEffect(0.8)
            }

            smallActionButton(label: "Abrir pasta do agente") {
                try? FileManager.default.createDirectory(
                    at: ClaudeCodeAgentRunner.agentWorkingDirectory,
                    withIntermediateDirectories: true
                )
                NSWorkspace.shared.open(ClaudeCodeAgentRunner.agentWorkingDirectory)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    // MARK: - Status checks

    private func refreshServiceStatus() {
        Task {
            isLocalModelOnline = await companionManager.localVisionModelClient.isServerReachable()
            isKokoroVoiceOnline = await Self.isKokoroServerReachable(baseURLString: hybridSettings.kokoroServerURL)
            isClaudeCodeInstalled = ClaudeCodeAgentRunner.locateClaudeCodeExecutable() != nil
        }
    }

    private static func isKokoroServerReachable(baseURLString: String) async -> Bool {
        let trimmedBaseURL = baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let modelsURL = URL(string: "\(trimmedBaseURL)/v1/models") else { return false }
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Small building blocks

    private func statusDot(isOnline: Bool?) -> some View {
        Circle()
            .fill(isOnline == nil ? DS.Colors.textTertiary : (isOnline == true ? DS.Colors.success : DS.Colors.warning))
            .frame(width: 6, height: 6)
    }

    private func serviceStatusRow(name: String, isOnline: Bool?, offlineHint: String) -> some View {
        HStack(spacing: 6) {
            statusDot(isOnline: isOnline)
            Text(name)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
            if isOnline == false {
                Text("— \(offlineHint)")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private func segmentedButtonGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func segmentButton(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func smallActionButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
