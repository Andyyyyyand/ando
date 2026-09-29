//
//  AccessibilityElementCollector.swift
//  leanring-buddy
//
//  Reads the clickable UI elements of the frontmost app through the macOS
//  Accessibility API. Each element comes with its exact on-screen frame, so
//  when the model says "point at element 7" the cursor lands exactly on it —
//  no guessing pixel coordinates from a screenshot. This is what lets a
//  small local model point as precisely as Claude.
//
//  Apps that don't expose an accessibility tree (games, some canvases)
//  return few or no elements; the model then falls back to [POINT:x,y].
//

import AppKit
import ApplicationServices

struct AccessibleScreenElement {
    /// 1-based number shown to the model in the element list.
    let elementNumber: Int
    let roleDescription: String
    let label: String
    /// Frame in Accessibility coordinates: global, top-left origin of the
    /// primary display, y grows downward.
    let frameInAccessibilityCoordinates: CGRect
}

struct AccessibilitySnapshot {
    let applicationName: String
    let elements: [AccessibleScreenElement]

    /// Compact list that is appended to the prompt, e.g.
    /// `[7] button "Save" (top right)`.
    var promptDescription: String {
        promptDescription(screenshotLocationDescription: { _ in nil })
    }

    /// Same list, with each element's position in screenshot pixels
    /// appended (e.g. `at (512,300)`), so the model can match the list to
    /// what it sees and pick the right one when labels repeat.
    func promptDescription(screenshotLocationDescription: (AccessibleScreenElement) -> String?) -> String {
        guard !elements.isEmpty else { return "" }
        let elementLines = elements.map { element in
            var elementLine = "[\(element.elementNumber)] \(element.roleDescription) \"\(element.label)\""
            if let locationDescription = screenshotLocationDescription(element) {
                elementLine += " " + locationDescription
            }
            return elementLine
        }
        return "clickable elements in \(applicationName) (from the accessibility tree):\n" + elementLines.joined(separator: "\n")
    }

    func element(withNumber elementNumber: Int) -> AccessibleScreenElement? {
        elements.first { $0.elementNumber == elementNumber }
    }
}

@MainActor
enum AccessibilityElementCollector {

    /// Roles worth pointing at. Plain static text and layout groups are
    /// skipped to keep the list short (fewer tokens, faster local model).
    private static let pointableRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXComboBox", "AXSlider", "AXLink",
        "AXMenuBarItem", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell",
        "AXSegmentedControl", "AXHeading", "AXTab", "AXImage", "AXCell"
    ]

    /// Roles that are useful even without a visible label (e.g. an empty
    /// search field is still something the user may need to find).
    private static let rolesUsefulWithoutLabel: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// Collects pointable elements from the frontmost app's focused window and
    /// its menu bar. Bounded by element count and wall-clock time so a huge
    /// tree (a long web page) never stalls the push-to-talk pipeline.
    static func collectFrontmostApplicationElements(
        maximumElementCount: Int = 120,
        timeBudgetSeconds: TimeInterval = 0.25
    ) -> AccessibilitySnapshot? {
        guard AXIsProcessTrusted(),
              let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        // A hung app must not hang us: cap each AX call at 200ms.
        AXUIElementSetMessagingTimeout(applicationElement, 0.2)
        // Chromium and Electron apps only build their accessibility tree when
        // an assistive app asks for it. Harmless for apps that ignore it.
        AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let deadline = Date().addingTimeInterval(timeBudgetSeconds)
        let visibleScreenBounds = visibleScreenBoundsInAccessibilityCoordinates()

        var rootElements: [AXUIElement] = []
        if let focusedWindow = copyElementAttribute(applicationElement, kAXFocusedWindowAttribute) {
            rootElements.append(focusedWindow)
        }
        if let menuBar = copyElementAttribute(applicationElement, kAXMenuBarAttribute) {
            rootElements.append(menuBar)
        }
        guard !rootElements.isEmpty else { return nil }

        var collectedElements: [AccessibleScreenElement] = []
        var seenElementKeys = Set<String>()
        // Breadth-first so the top-level structure (toolbars, sidebars) is
        // captured before deep content if the time budget runs out.
        var elementsToVisit: [(element: AXUIElement, depth: Int)] = rootElements.map { ($0, 0) }
        var visitIndex = 0
        let maximumDepth = 30
        let maximumVisitedElementCount = 4000

        while visitIndex < elementsToVisit.count
                && collectedElements.count < maximumElementCount
                && visitIndex < maximumVisitedElementCount
                && Date() < deadline {
            let (currentElement, currentDepth) = elementsToVisit[visitIndex]
            visitIndex += 1

            let role = copyStringAttribute(currentElement, kAXRoleAttribute) ?? ""

            if pointableRoles.contains(role),
               let elementFrame = copyFrame(of: currentElement),
               elementFrame.width >= 4, elementFrame.height >= 4,
               visibleScreenBounds.intersects(elementFrame) {
                let label = bestLabel(for: currentElement)
                if !label.isEmpty || rolesUsefulWithoutLabel.contains(role) {
                    let elementKey = "\(label)|\(Int(elementFrame.midX))|\(Int(elementFrame.midY))"
                    if !seenElementKeys.contains(elementKey) {
                        seenElementKeys.insert(elementKey)
                        let roleDescription = copyStringAttribute(currentElement, kAXRoleDescriptionAttribute)
                            ?? role.replacingOccurrences(of: "AX", with: "").lowercased()
                        collectedElements.append(AccessibleScreenElement(
                            elementNumber: collectedElements.count + 1,
                            roleDescription: roleDescription,
                            label: label.isEmpty ? "(no label)" : label,
                            frameInAccessibilityCoordinates: elementFrame
                        ))
                    }
                }
            }

            // Menu bar items have huge submenus that are not on screen until
            // opened — don't descend into them.
            guard currentDepth < maximumDepth, role != "AXMenuBarItem" else { continue }
            if let childElements = copyChildElements(currentElement) {
                for childElement in childElements {
                    elementsToVisit.append((childElement, currentDepth + 1))
                }
            }
        }

        print("♿️ Accessibility: \(collectedElements.count) elements from \(frontmostApplication.localizedName ?? "app") (visited \(visitIndex))")

        return AccessibilitySnapshot(
            applicationName: frontmostApplication.localizedName ?? "the frontmost app",
            elements: collectedElements
        )
    }

    /// Converts an element's Accessibility frame center into AppKit global
    /// coordinates (bottom-left origin), which is what the cursor overlay uses.
    static func appKitCenterPoint(of element: AccessibleScreenElement) -> CGPoint {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let elementFrame = element.frameInAccessibilityCoordinates
        return CGPoint(x: elementFrame.midX, y: primaryScreenHeight - elementFrame.midY)
    }

    // MARK: - Private helpers

    private static func bestLabel(for element: AXUIElement) -> String {
        let candidateAttributes = [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXValueAttribute,
            "AXPlaceholderValue",
            kAXHelpAttribute
        ]
        for attribute in candidateAttributes {
            if let value = copyStringAttribute(element, attribute) {
                let trimmedValue = value
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedValue.isEmpty {
                    // Long values (e.g. a whole text document) are noise.
                    return String(trimmedValue.prefix(60))
                }
            }
        }
        return ""
    }

    /// Union of all displays in Accessibility coordinates, used to drop
    /// elements that are scrolled out of view.
    private static func visibleScreenBoundsInAccessibilityCoordinates() -> CGRect {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        var unionOfScreenFrames = CGRect.null
        for screen in NSScreen.screens {
            let appKitFrame = screen.frame
            let accessibilityFrame = CGRect(
                x: appKitFrame.minX,
                y: primaryScreenHeight - appKitFrame.maxY,
                width: appKitFrame.width,
                height: appKitFrame.height
            )
            unionOfScreenFrames = unionOfScreenFrames.union(accessibilityFrame)
        }
        return unionOfScreenFrames
    }

    private static func copyAttributeValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var attributeValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue)
        guard result == .success else { return nil }
        return attributeValue
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttributeValue(element, attribute) as? String
    }

    private static func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let attributeValue = copyAttributeValue(element, attribute),
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (attributeValue as! AXUIElement)
    }

    private static func copyChildElements(_ element: AXUIElement) -> [AXUIElement]? {
        copyAttributeValue(element, kAXChildrenAttribute) as? [AXUIElement]
    }

    private static func copyFrame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttributeValue(element, kAXPositionAttribute),
              let sizeValue = copyAttributeValue(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var elementPosition = CGPoint.zero
        var elementSize = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &elementPosition),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &elementSize) else {
            return nil
        }
        return CGRect(origin: elementPosition, size: elementSize)
    }
}
