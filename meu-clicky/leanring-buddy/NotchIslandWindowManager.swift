//
//  NotchIslandWindowManager.swift
//  leanring-buddy
//
//  The black "island" that wraps the MacBook notch, like HeyClicky's: a
//  badge on the left counts agents that are working or have unread results,
//  and the blue Clicky triangle sits on the right (glowing while Clicky is
//  listening, thinking or an agent is busy). Clicking it opens the panel.
//
//  Only shown on displays that have a notch.
//

import AppKit
import SwiftUI

/// Borderless panel that can take a click without activating the app.
private final class NotchIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchIslandWindowManager {
    private var islandPanel: NSPanel?
    private let companionManager: CompanionManager
    private let onIslandClicked: () -> Void
    private var screenParametersObserver: NSObjectProtocol?

    /// Width of each black "wing" beside the notch.
    private let islandWingWidth: CGFloat = 46

    init(companionManager: CompanionManager, onIslandClicked: @escaping () -> Void) {
        self.companionManager = companionManager
        self.onIslandClicked = onIslandClicked

        rebuildIsland()

        // Displays connected/disconnected or resolution changed: re-place it.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildIsland()
            }
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    private func rebuildIsland() {
        islandPanel?.orderOut(nil)
        islandPanel = nil

        guard let notchedScreen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            return
        }

        let notchHeight = notchedScreen.safeAreaInsets.top
        let leftOfNotchWidth = notchedScreen.auxiliaryTopLeftArea?.width ?? 0
        let rightOfNotchWidth = notchedScreen.auxiliaryTopRightArea?.width ?? 0
        let notchWidth = max(120, notchedScreen.frame.width - leftOfNotchWidth - rightOfNotchWidth)
        let islandWidth = notchWidth + islandWingWidth * 2

        let islandFrame = NSRect(
            x: notchedScreen.frame.midX - islandWidth / 2,
            y: notchedScreen.frame.maxY - notchHeight,
            width: islandWidth,
            height: notchHeight
        )

        let newIslandPanel = NotchIslandPanel(
            contentRect: islandFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the menu bar so it can sit around the notch.
        newIslandPanel.level = .statusBar
        newIslandPanel.isOpaque = false
        newIslandPanel.backgroundColor = .clear
        newIslandPanel.hasShadow = false
        newIslandPanel.hidesOnDeactivate = false
        newIslandPanel.isExcludedFromWindowsMenu = true
        newIslandPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let islandView = NotchIslandView(
            companionManager: companionManager,
            agentCoordinator: companionManager.agentCoordinator,
            notchWidth: notchWidth,
            wingWidth: islandWingWidth,
            onClick: onIslandClicked
        )
        let hostingView = NSHostingView(rootView: islandView)
        hostingView.frame = NSRect(origin: .zero, size: islandFrame.size)
        newIslandPanel.contentView = hostingView
        newIslandPanel.setFrame(islandFrame, display: true)
        newIslandPanel.orderFrontRegardless()

        islandPanel = newIslandPanel
    }
}

private struct NotchIslandView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var agentCoordinator: AgentCoordinator
    let notchWidth: CGFloat
    let wingWidth: CGFloat
    let onClick: () -> Void

    @State private var isGlowPulsing = false

    private var isClickyBusy: Bool {
        companionManager.voiceState != .idle || agentCoordinator.runningTaskCount > 0
    }

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 0) {
                // Left wing: attention badge
                ZStack {
                    if agentCoordinator.attentionCount > 0 {
                        Text("\(agentCoordinator.attentionCount)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(Color(red: 0.1, green: 0.12, blue: 0.3))
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .fill(Color(red: 0.88, green: 0.9, blue: 1.0))
                                    .overlay(Circle().stroke(Color(red: 0.35, green: 0.45, blue: 1.0), lineWidth: 1.5))
                            )
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: wingWidth)

                // The notch itself (hardware) sits here.
                Color.clear
                    .frame(width: notchWidth)

                // Right wing: the Clicky triangle
                Triangle()
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(90))
                    .shadow(
                        color: DS.Colors.overlayCursorBlue.opacity(isClickyBusy ? (isGlowPulsing ? 1.0 : 0.4) : 0.6),
                        radius: isClickyBusy ? 8 : 5
                    )
                    .frame(width: wingWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 12,
                    style: .continuous
                )
                .fill(Color.black)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: agentCoordinator.attentionCount)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isGlowPulsing = true
            }
        }
    }
}
