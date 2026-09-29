//
//  ClickyHomePanelView.swift
//  leanring-buddy
//
//  The main menu bar panel once Clicky is set up, modeled on HeyClicky's
//  home: a near-black card listing agents like conversations (avatar, name,
//  time, latest message, unread dot), a tips row at the top, and glossy
//  pill buttons at the bottom. The gear swaps the list for settings.
//

import AppKit
import SwiftUI

struct ClickyHomePanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var hybridSettings: HybridSettings
    @ObservedObject var agentCoordinator: AgentCoordinator

    @State private var isShowingSettings = false
    @State private var isShowingTips = false
    @State private var expandedAgentTaskID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if isShowingSettings {
                ScrollView {
                    HybridControlsPanelSection(
                        companionManager: companionManager,
                        hybridSettings: hybridSettings,
                        agentCoordinator: agentCoordinator,
                        isSettingsScreen: true
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                homeList
            }

            footer
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 16)
        }
        .frame(width: ClickyHomeStyle.panelWidth)
        .background(
            RoundedRectangle(cornerRadius: ClickyHomeStyle.panelCornerRadius, style: .continuous)
                .fill(ClickyHomeStyle.panelBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: ClickyHomeStyle.panelCornerRadius, style: .continuous)
                        .stroke(ClickyHomeStyle.panelBorder, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.55), radius: 24, x: 0, y: 12)
        )
        .onAppear {
            agentCoordinator.markFinishedTasksSeen()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("^^")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundColor(.white)

            // Which brain is answering, styled like the original's top pill.
            Button(action: { toggleSettings() }) {
                Text(brainPillLabel)
            }
            .buttonStyle(GlossyPillButtonStyle(variant: .blue))
            .pointerCursor()

            Spacer()

            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ClickyHomeStyle.previewText)

            iconButton(systemName: isShowingSettings ? "xmark.circle.fill" : "gearshape.fill") {
                toggleSettings()
            }

            // Quit Clicky (the menu bar icon is hidden on notch Macs, so the
            // panel is the only place to close the app).
            iconButton(systemName: "power") {
                NSApp.terminate(nil)
            }
            .help("Fechar o Clicky")
        }
    }

    private var brainPillLabel: String {
        switch hybridSettings.brainMode {
        case .localOnly:
            return "Local"
        case .claudeOnly, .automatic:
            let modelLabel = HybridSettings.claudeModelOptions
                .first(where: { $0.value == hybridSettings.claudeModel })?.label ?? "Claude"
            return hybridSettings.brainMode == .automatic ? "Auto · \(modelLabel)" : modelLabel
        }
    }

    private var statusText: String {
        switch companionManager.voiceState {
        case .idle: return "Pronto"
        case .listening: return "Ouvindo…"
        case .processing: return "Pensando…"
        case .responding: return "Falando…"
        }
    }

    // MARK: - Home list

    private var homeList: some View {
        ScrollView {
            VStack(spacing: 0) {
                tipsRow

                if agentCoordinator.tasks.isEmpty {
                    emptyState
                } else {
                    ForEach(agentCoordinator.tasks) { agentTask in
                        rowDivider
                        agentRow(agentTask)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(ClickyHomeStyle.divider)
            .frame(height: 1)
            .padding(.leading, 76)
            .padding(.trailing, 8)
    }

    /// Highlighted first row, like the original's "Suggestions" entry.
    private var tipsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                isShowingTips.toggle()
                NotificationCenter.default.post(name: .clickyPanelContentSizeChanged, object: nil)
            }) {
                HStack(spacing: 14) {
                    SparkleAvatarView()
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Dicas")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(ClickyHomeStyle.titleText)
                            Text("3")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(ClickyHomeStyle.titleText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                        Text("Segure ctrl + option e pergunte sobre qualquer coisa na tela")
                            .font(.system(size: 13))
                            .foregroundColor(ClickyHomeStyle.previewText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isShowingTips {
                VStack(alignment: .leading, spacing: 8) {
                    tipLine(keys: ["ctrl", "option"], text: "Perguntar sobre a tela, abrir apps e sites")
                    tipLine(keys: ["ctrl", "option", "shift"], text: "Ditar texto no app aberto")
                    tipLine(keys: ["ctrl", "option"], text: "Diga \"agente, …\" para delegar uma tarefa")
                }
                .padding(.leading, 60)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ClickyHomeStyle.rowHighlight)
        )
        .padding(.bottom, 4)
    }

    private func tipLine(keys: [String], text: String) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { keyLabel in
                Text(keyLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.14)))
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(ClickyHomeStyle.previewText)
                .lineLimit(2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Nenhum agente ainda")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ClickyHomeStyle.titleText)
            Text("Segure ctrl + option e diga \"agente, pesquisa…\" ou \"agente, rascunha um e-mail…\"")
                .font(.system(size: 12))
                .foregroundColor(ClickyHomeStyle.previewText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }

    private func agentRow(_ agentTask: AgentTaskRecord) -> some View {
        let isExpanded = expandedAgentTaskID == agentTask.id
        let isUnread = !agentTask.hasBeenSeen && agentTask.status != .running

        return VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                expandedAgentTaskID = isExpanded ? nil : agentTask.id
                NotificationCenter.default.post(name: .clickyPanelContentSizeChanged, object: nil)
            }) {
                HStack(spacing: 14) {
                    ZStack(alignment: .leading) {
                        BuddyAvatarView(seedName: agentTask.agentName)
                            .overlay(alignment: .bottomTrailing) {
                                if agentTask.status == .running {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .padding(3)
                                        .background(Circle().fill(ClickyHomeStyle.panelBackground))
                                }
                            }
                        if isUnread {
                            Circle()
                                .fill(ClickyHomeStyle.unreadDot)
                                .frame(width: 9, height: 9)
                                .offset(x: -16)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(agentTask.agentName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(ClickyHomeStyle.titleText)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(ConversationTimeLabel.text(for: agentTask.finishedAt ?? agentTask.startedAt))
                                .font(.system(size: 12))
                                .foregroundColor(ClickyHomeStyle.previewText)
                        }
                        Text(rowPreviewText(agentTask))
                            .font(.system(size: 13))
                            .foregroundColor(ClickyHomeStyle.previewText)
                            .lineLimit(isExpanded ? 6 : 1)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                agentDetail(agentTask)
                    .padding(.leading, 72)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    private func rowPreviewText(_ agentTask: AgentTaskRecord) -> String {
        switch agentTask.status {
        case .running:
            return agentTask.logLines.last ?? agentTask.taskText
        case .completed, .failed:
            return agentTask.summary ?? agentTask.taskText
        case .cancelled:
            return "Cancelado · \(agentTask.taskText)"
        }
    }

    private func agentDetail(_ agentTask: AgentTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pedido: \(agentTask.taskText)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(ClickyHomeStyle.titleText)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(agentTask.logLines.enumerated()), id: \.offset) { _, logLine in
                        Text(logLine)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(ClickyHomeStyle.previewText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxHeight: 130)

            HStack(spacing: 8) {
                if agentTask.status == .running {
                    Button("Parar") { agentCoordinator.cancelTask(taskID: agentTask.id) }
                        .buttonStyle(GlossyPillButtonStyle(variant: .dark))
                        .pointerCursor()
                }
                Button("Abrir pasta") { openAgentFolder() }
                    .buttonStyle(GlossyPillButtonStyle(variant: .dark))
                    .pointerCursor()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: { openAgentFolder() }) {
                Label("Pasta", systemImage: "folder")
            }
            .buttonStyle(GlossyPillButtonStyle(variant: .dark))
            .pointerCursor()

            Button(action: {
                if let connectorsURL = URL(string: "https://claude.ai/customize/connectors") {
                    NSWorkspace.shared.open(connectorsURL)
                }
            }) {
                Label("Conectar apps", systemImage: "link")
            }
            .buttonStyle(GlossyPillButtonStyle(variant: .green))
            .pointerCursor()

            Spacer(minLength: 0)

            Button(action: {
                agentCoordinator.clearFinishedTasks()
                NotificationCenter.default.post(name: .clickyPanelContentSizeChanged, object: nil)
            }) {
                Label("Limpar", systemImage: "sparkles")
            }
            .buttonStyle(GlossyPillButtonStyle(variant: .light))
            .pointerCursor()
        }
    }

    // MARK: - Helpers

    private func toggleSettings() {
        isShowingSettings.toggle()
        NotificationCenter.default.post(name: .clickyPanelContentSizeChanged, object: nil)
    }

    private func openAgentFolder() {
        try? FileManager.default.createDirectory(
            at: ClaudeCodeAgentRunner.agentWorkingDirectory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(ClaudeCodeAgentRunner.agentWorkingDirectory)
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.8))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
