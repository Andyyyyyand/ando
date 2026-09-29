//
//  DictationTextInserter.swift
//  leanring-buddy
//
//  Types dictated text into whatever app has keyboard focus. The text is
//  placed on the clipboard and pasted with a synthetic Cmd+V (works in every
//  app, including web text fields), then the user's previous clipboard is
//  restored so dictation never clobbers what they had copied.
//

import AppKit
import CoreGraphics

@MainActor
enum DictationTextInserter {

    /// Virtual key code for "V" (same on US and ABNT2 layouts).
    private static let pasteKeyCode: CGKeyCode = 9

    static func insertTextIntoFocusedApp(_ textToInsert: String) {
        let trimmedTextToInsert = textToInsert.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTextToInsert.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let savedPasteboardItems = copyOfCurrentPasteboardItems(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(trimmedTextToInsert, forType: .string)
        let changeCountAfterOurWrite = pasteboard.changeCount

        postCommandV()

        // Give the target app time to read the clipboard before restoring it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // If the user copied something else in the meantime, keep theirs.
            guard pasteboard.changeCount == changeCountAfterOurWrite else { return }
            pasteboard.clearContents()
            if !savedPasteboardItems.isEmpty {
                pasteboard.writeObjects(savedPasteboardItems)
            }
        }
        print("⌨️ Dictation: inserted \(trimmedTextToInsert.count) characters")
    }

    private static func postCommandV() {
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: pasteKeyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: pasteKeyCode, keyDown: false)
        keyDownEvent?.flags = .maskCommand
        keyUpEvent?.flags = .maskCommand
        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }

    private static func copyOfCurrentPasteboardItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { originalItem in
            let copiedItem = NSPasteboardItem()
            for pasteboardType in originalItem.types {
                if let itemData = originalItem.data(forType: pasteboardType) {
                    copiedItem.setData(itemData, forType: pasteboardType)
                }
            }
            return copiedItem
        }
    }
}
