//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Claude is called directly with the user's own API key (stored in the
    /// Keychain). Only used for hard questions in automatic mode.
    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(model: HybridSettings.shared.claudeModel)
    }()

    /// Free vision model running on this Mac (Ollama by default).
    let localVisionModelClient = LocalVisionModelClient()

    /// Free on-device voice (Kokoro via mlx-audio, macOS voice as fallback).
    private let localSpeechOutput = LocalSpeechOutput()

    /// Background agents started by saying "agente, ...".
    private(set) lazy var agentCoordinator: AgentCoordinator = {
        return AgentCoordinator(
            localVisionModelClient: localVisionModelClient,
            speakAnnouncement: { [weak self] announcementText in
                self?.speakAgentAnnouncementWhenIdle(announcementText)
            }
        )
    }()

    /// Which brain answered the most recent question, shown in the panel.
    @Published private(set) var lastAnsweringBrainDescription: String?

    /// The answer currently being spoken, shown as text next to the blue
    /// cursor. Empty when nothing should be shown.
    @Published private(set) var spokenResponseBubbleText: String = ""

    /// Hides the response bubble a few seconds after speech ends.
    private var spokenResponseBubbleHideTask: Task<Void, Never>?

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        if HybridSettings.shared.hasClaudeAPIKey {
            _ = claudeAPI
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    /// Shows `responseText` next to the cursor and keeps it up while the
    /// voice plays, then fades it out a few seconds after speech ends.
    private func showSpokenResponseBubble(_ responseText: String) {
        spokenResponseBubbleHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            spokenResponseBubbleText = responseText
        }

        spokenResponseBubbleHideTask = Task {
            // Give playback a moment to start before polling isPlaying.
            try? await Task.sleep(nanoseconds: 500_000_000)
            while localSpeechOutput.isPlaying {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            // Leave the text up briefly so the user can finish reading.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            hideSpokenResponseBubble()
        }
    }

    private func hideSpokenResponseBubble() {
        spokenResponseBubbleHideTask?.cancel()
        spokenResponseBubbleHideTask = nil
        withAnimation(.easeOut(duration: 0.3)) {
            spokenResponseBubbleText = ""
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            localSpeechOutput.stopPlayback()
            clearDetectedElementLocation()
            hideSpokenResponseBubble()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.handleFinalTranscript(finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    language: reply in brazilian portuguese unless the user clearly speaks another language, in which case reply in their language.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "por exemplo" not "ex.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simplesmente" or "é só".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "quer que eu explique mais?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing.

    don't point at things when it would be pointless — like a general knowledge question, or you'd just be pointing at something obvious they're already looking at.

    there are two ways to point. always append the tag at the very end of your response, AFTER your spoken text.

    1. preferred: the user message may include a numbered list of clickable elements read from the app's accessibility tree. if the thing you want to point at is in that list, append [ELEMENT:n:label] where n is its number and label is a short 1-3 word description. this lands exactly on the element.

    2. fallback: if the element is not in the list (or there is no list), append [POINT:x,y:label] using the screenshot's pixel coordinates. the screenshot images are labeled with their pixel dimensions. origin (0,0) is the top-left corner. x increases rightward, y increases downward. if the element is on a DIFFERENT screen than the cursor, append :screenN (e.g. [POINT:400,300:terminal:screen2]).

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut and the list has "[12] button "Color Inspector"": "abre o inspetor de cor, ele fica ali no canto de cima da barra de ferramentas. clica nele e aparecem as rodas de cor e as curvas. [ELEMENT:12:inspetor de cor]"
    - user asks what html is: "html é a linguagem de marcação de hipertexto, é basicamente o esqueleto de toda página web. dá uma olhada em como ela se conecta com o css que você está vendo. [POINT:none]"
    - no list available, user asks how to commit in xcode: "tá vendo o menu source control lá em cima? clica nele e escolhe commit, ou usa command option c. [POINT:285,11:source control]"
    """

    /// Shorter prompt for the small local model. Small models follow short,
    /// concrete instructions better than long ones.
    private static func localModelSystemPrompt(canEscalateToClaude: Bool) -> String {
        var localPrompt = """
        you are clicky, a voice assistant that can see the user's screen. your reply is spoken aloud.
        reply in brazilian portuguese, in one or two short, casual sentences, all lowercase, no emojis, no lists, no markdown.

        pointing: at the very end of your reply add exactly one tag:
        - [ELEMENT:n:label] if the thing to click is in the numbered list of clickable elements (n is its number).
        - [POINT:x,y:label] with screenshot pixel coordinates if it is not in the list.
        - [POINT:none] if pointing doesn't help.
        """
        if canEscalateToClaude {
            localPrompt += """


            if the question needs careful reasoning, a long explanation, reading or fixing code, math, or you are not confident in the answer, reply with exactly \(HybridBrainRouter.localEscalationMarker) and nothing else. a smarter model will answer instead.
            """
        }
        return localPrompt
    }

    // MARK: - Transcript Routing

    /// Agent requests ("agente, ...") go to the background agent; everything
    /// else is answered right away by the hybrid brain.
    private func handleFinalTranscript(_ transcript: String) {
        if let agentTaskText = AgentCoordinator.extractAgentTaskText(from: transcript) {
            currentResponseTask?.cancel()
            currentResponseTask = nil
            localSpeechOutput.stopPlayback()
            voiceState = .idle
            agentCoordinator.startAgentTask(taskText: agentTaskText)
            scheduleTransientHideIfNeeded()
            return
        }

        sendTranscriptToClaudeWithScreenshot(transcript: transcript)
    }

    /// Speaks an agent update without talking over an answer that is being
    /// prepared or played, or over the user while they are holding the hotkey.
    private func speakAgentAnnouncementWhenIdle(_ announcementText: String) {
        Task {
            var secondsWaited: Double = 0
            while (voiceState != .idle || localSpeechOutput.isPlaying || buddyDictationManager.isDictationInProgress)
                    && secondsWaited < 60 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                secondsWaited += 0.3
            }
            do {
                try await localSpeechOutput.speakText(announcementText)
            } catch {
                print("⚠️ Agent announcement TTS error: \(error)")
            }
        }
    }

    /// Picks the local model or Claude for this question (see
    /// HybridBrainRouter) and returns the raw answer, including any
    /// [ELEMENT]/[POINT] tag.
    private func answerWithHybridBrain(
        transcript: String,
        labeledImages: [(data: Data, label: String)],
        historyForAPI: [(userPlaceholder: String, assistantResponse: String)],
        userPromptWithContext: String
    ) async throws -> String {
        let settings = HybridSettings.shared
        let isLocalModelReachable = await localVisionModelClient.isServerReachable()
        let brainChoice = HybridBrainRouter.chooseBrain(
            forTranscript: transcript,
            brainMode: settings.brainMode,
            hasClaudeAPIKey: settings.hasClaudeAPIKey,
            isLocalModelReachable: isLocalModelReachable
        )

        if brainChoice == .localModel {
            let canEscalateToClaude = settings.hasClaudeAPIKey && settings.brainMode == .automatic
            do {
                let localAnswer = try await localVisionModelClient.analyzeImages(
                    images: labeledImages,
                    systemPrompt: Self.localModelSystemPrompt(canEscalateToClaude: canEscalateToClaude),
                    conversationHistory: historyForAPI,
                    userPrompt: userPromptWithContext
                )
                if !(canEscalateToClaude && HybridBrainRouter.localAnswerRequestsEscalation(localAnswer)) {
                    lastAnsweringBrainDescription = "Local · \(settings.localVisionModelName)"
                    print("🧭 Answered by local model")
                    return localAnswer
                }
                print("🧭 Local model escalated the question to Claude")
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // Only fall back when Claude is actually available.
                guard settings.hasClaudeAPIKey else { throw error }
                print("⚠️ Local model failed (\(error.localizedDescription)) — falling back to Claude")
            }
        }

        if Task.isCancelled { throw CancellationError() }

        claudeAPI.model = settings.claudeModel
        let (claudeAnswer, _) = try await claudeAPI.analyzeImageStreaming(
            images: labeledImages,
            systemPrompt: Self.companionVoiceResponseSystemPrompt,
            conversationHistory: historyForAPI,
            userPrompt: userPromptWithContext,
            onTextChunk: { _ in
                // No streaming text display — spinner stays until TTS plays
            }
        )
        lastAnsweringBrainDescription = "Claude · \(settings.claudeModel)"
        print("🧭 Answered by Claude")
        return claudeAnswer
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot and the frontmost app's clickable elements, gets
    /// an answer from the hybrid brain, and plays it aloud. The cursor stays
    /// in the spinner/processing state until TTS audio begins playing. The
    /// answer may include an [ELEMENT:n] or [POINT:x,y] tag which makes the
    /// buddy fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        localSpeechOutput.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Exact positions of buttons, menus and fields from the macOS
                // Accessibility API, so pointing doesn't depend on the model
                // guessing pixel coordinates.
                let accessibilitySnapshot = AccessibilityElementCollector.collectFrontmostApplicationElements()

                // Build image labels with the actual screenshot pixel dimensions
                // so the model's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so the model remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                var userPromptWithContext = transcript
                if let accessibilitySnapshot, !accessibilitySnapshot.elements.isEmpty {
                    userPromptWithContext = accessibilitySnapshot.promptDescription
                        + "\n\nuser's question: " + transcript
                }

                let fullResponseText = try await answerWithHybridBrain(
                    transcript: transcript,
                    labeledImages: labeledImages,
                    historyForAPI: historyForAPI,
                    userPromptWithContext: userPromptWithContext
                )

                guard !Task.isCancelled else { return }

                // Parse the [ELEMENT:n] tag first, then the [POINT:...] tag
                let elementParseResult = Self.parseAccessibilityElementTag(from: fullResponseText)
                let parseResult = Self.parsePointingCoordinates(from: elementParseResult.textWithoutElementTag)
                let spokenText = parseResult.spokenText

                // Preferred path: point at the exact accessibility element.
                var didPointAtAccessibilityElement = false
                if let elementNumber = elementParseResult.elementNumber,
                   let accessibleElement = accessibilitySnapshot?.element(withNumber: elementNumber) {
                    let globalLocation = AccessibilityElementCollector.appKitCenterPoint(of: accessibleElement)
                    if let elementDisplayFrame = NSScreen.screens.first(where: { $0.frame.contains(globalLocation) })?.frame {
                        // Switch to idle BEFORE setting the location so the
                        // triangle is visible for the flight animation.
                        voiceState = .idle
                        detectedElementScreenLocation = globalLocation
                        detectedElementDisplayFrame = elementDisplayFrame
                        didPointAtAccessibilityElement = true
                        ClickyAnalytics.trackElementPointed(elementLabel: elementParseResult.elementLabel)
                        print("🎯 Element pointing (accessibility): #\(elementNumber) \"\(accessibleElement.label)\"")
                    }
                }

                if !didPointAtAccessibilityElement {
                    // Handle element pointing if the model returned coordinates.
                    // Switch to idle BEFORE setting the location so the triangle
                    // becomes visible and can fly to the target. Without this, the
                    // spinner hides the triangle and the flight animation is invisible.
                    let hasPointCoordinate = parseResult.coordinate != nil
                    if hasPointCoordinate {
                        voiceState = .idle
                    }

                    // Pick the screen capture matching the model's screen number,
                    // falling back to the cursor screen if not specified.
                    let targetScreenCapture: CompanionScreenCapture? = {
                        if let screenNumber = parseResult.screenNumber,
                           screenNumber >= 1 && screenNumber <= screenCaptures.count {
                            return screenCaptures[screenNumber - 1]
                        }
                        return screenCaptures.first(where: { $0.isCursorScreen })
                    }()

                    if let pointCoordinate = parseResult.coordinate,
                       let targetScreenCapture {
                        // The coordinates are in the screenshot's pixel space
                        // (top-left origin, e.g. 1280x831). Scale to the display's
                        // point space (e.g. 1512x982), then convert to AppKit global coords.
                        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                        let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                        let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                        let displayFrame = targetScreenCapture.displayFrame

                        // Clamp to screenshot coordinate space
                        let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                        let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                        // Scale from screenshot pixels to display points
                        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                        // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                        let appKitY = displayHeight - displayLocalY

                        // Convert display-local coords to global screen coords
                        let globalLocation = CGPoint(
                            x: displayLocalX + displayFrame.origin.x,
                            y: appKitY + displayFrame.origin.y
                        )

                        detectedElementScreenLocation = globalLocation
                        detectedElementDisplayFrame = displayFrame
                        ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                        print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                    } else {
                        print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                    }
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await localSpeechOutput.speakText(spokenText)
                        // speakText returns after playback starts — audio is now playing
                        voiceState = .responding
                        showSpokenResponseBubble(spokenText)
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ TTS error: \(error)")
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                // A cancelled network request surfaces as URLError, not
                // CancellationError — stay quiet when the user already moved on.
                if !Task.isCancelled {
                    ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                    print("⚠️ Companion response error: \(error)")
                    speakResponseErrorFallback()
                }
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while localSpeechOutput.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a short error with the built-in macOS voice, which works even
    /// when the local servers and Claude are all unreachable.
    private func speakResponseErrorFallback() {
        let errorUtterance: String
        if HybridSettings.shared.hasClaudeAPIKey {
            errorUtterance = "tive um problema para responder agora. tenta de novo daqui a pouco."
        } else {
            errorUtterance = "não consegui falar com o modelo local. confere se o ollama está aberto e tenta de novo."
        }
        localSpeechOutput.speakWithSystemVoice(errorUtterance)
        voiceState = .responding
    }

    // MARK: - Accessibility Element Tag Parsing

    struct AccessibilityElementTagParseResult {
        /// The response text with the [ELEMENT:...] tag removed.
        let textWithoutElementTag: String
        /// The element number from the accessibility list, if the model chose one.
        let elementNumber: Int?
        let elementLabel: String?
    }

    /// Parses an [ELEMENT:n] or [ELEMENT:n:label] tag at the end of the answer.
    static func parseAccessibilityElementTag(from responseText: String) -> AccessibilityElementTagParseResult {
        let pattern = #"\[ELEMENT:\s*(\d+)\s*(?::([^\]]*))?\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let tagRange = Range(match.range, in: responseText),
              let numberRange = Range(match.range(at: 1), in: responseText) else {
            return AccessibilityElementTagParseResult(textWithoutElementTag: responseText, elementNumber: nil, elementLabel: nil)
        }

        let textWithoutElementTag = String(responseText[..<tagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var elementLabel: String? = nil
        if let labelRange = Range(match.range(at: 2), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        return AccessibilityElementTagParseResult(
            textWithoutElementTag: textWithoutElementTag,
            elementNumber: Int(responseText[numberRange]),
            elementLabel: elementLabel
        )
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "segure control + option e se apresente"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation, in brazilian portuguese, about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                // Use Claude when a key is configured, otherwise the local model.
                let fullResponseText: String
                if HybridSettings.shared.hasClaudeAPIKey {
                    claudeAPI.model = HybridSettings.shared.claudeModel
                    fullResponseText = try await claudeAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: Self.onboardingDemoSystemPrompt,
                        userPrompt: "look around my screen and find something interesting to point at",
                        onTextChunk: { _ in }
                    ).text
                } else {
                    fullResponseText = try await localVisionModelClient.analyzeImages(
                        images: labeledImages,
                        systemPrompt: Self.onboardingDemoSystemPrompt,
                        conversationHistory: [],
                        userPrompt: "look around my screen and find something interesting to point at"
                    )
                }

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
