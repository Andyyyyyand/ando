//
//  MacQuickActions.swift
//  leanring-buddy
//
//  Small, instant actions the local agent can run on this Mac without any
//  cloud model: reminders, calendar events, notes, opening apps and links.
//  Reminders/Calendar/Notes are driven through AppleScript, so macOS asks
//  once per app for Automation permission the first time each is used.
//

import AppKit
import Foundation

enum MacQuickActionError: LocalizedError {
    case appleScriptFailed(String)
    case invalidParameters(String)

    var errorDescription: String? {
        switch self {
        case .appleScriptFailed(let message): return "AppleScript: \(message)"
        case .invalidParameters(let message): return message
        }
    }
}

@MainActor
enum MacQuickActions {

    static func createReminder(title: String, dueDate: Date?) throws {
        var scriptLines = ["tell application \"Reminders\""]
        if let dueDate {
            scriptLines.append(contentsOf: appleScriptLinesBuildingDate(dueDate, variableName: "reminderDueDate"))
            scriptLines.append("make new reminder with properties {name:\"\(escapeForAppleScript(title))\", remind me date:reminderDueDate}")
        } else {
            scriptLines.append("make new reminder with properties {name:\"\(escapeForAppleScript(title))\"}")
        }
        scriptLines.append("end tell")
        try runAppleScript(scriptLines.joined(separator: "\n"))
    }

    static func createCalendarEvent(title: String, startDate: Date, durationMinutes: Int) throws {
        let safeDurationMinutes = max(5, min(durationMinutes, 24 * 60))
        var scriptLines = ["tell application \"Calendar\""]
        scriptLines.append(contentsOf: appleScriptLinesBuildingDate(startDate, variableName: "eventStartDate"))
        scriptLines.append(contentsOf: [
            "set eventEndDate to eventStartDate + (\(safeDurationMinutes) * minutes)",
            "set targetCalendar to first calendar whose writable is true",
            "make new event at end of events of targetCalendar with properties {summary:\"\(escapeForAppleScript(title))\", start date:eventStartDate, end date:eventEndDate}",
            "end tell"
        ])
        try runAppleScript(scriptLines.joined(separator: "\n"))
    }

    static func createNote(title: String, body: String) throws {
        // Notes stores HTML; the first line becomes the note title.
        let htmlBody = "<div><b>\(escapeForHTML(title))</b></div>" + body
            .components(separatedBy: "\n")
            .map { "<div>\(escapeForHTML($0))</div>" }
            .joined()
        let script = """
        tell application "Notes"
            try
                set targetFolder to default folder of default account
            on error
                set targetFolder to folder 1 of default account
            end try
            make new note at targetFolder with properties {body:"\(escapeForAppleScript(htmlBody))"}
        end tell
        """
        try runAppleScript(script)
    }

    static func openApplication(named applicationName: String) throws {
        let trimmedApplicationName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApplicationName.isEmpty else {
            throw MacQuickActionError.invalidParameters("Nome do app vazio")
        }
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", trimmedApplicationName]
        try openProcess.run()
        openProcess.waitUntilExit()
        guard openProcess.terminationStatus == 0 else {
            throw MacQuickActionError.invalidParameters("Não encontrei o app \(trimmedApplicationName)")
        }
    }

    static func openURL(_ urlString: String) throws {
        var normalizedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedURLString.lowercased().hasPrefix("http") {
            normalizedURLString = "https://" + normalizedURLString
        }
        guard let url = URL(string: normalizedURLString) else {
            throw MacQuickActionError.invalidParameters("Link inválido: \(urlString)")
        }
        NSWorkspace.shared.open(url)
    }

    /// Opens a folder in Finder or a file in its default app. Accepts "~".
    static func openPath(_ pathText: String) throws {
        let expandedPath = (pathText.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !expandedPath.isEmpty, FileManager.default.fileExists(atPath: expandedPath) else {
            throw MacQuickActionError.invalidParameters("Não encontrei: \(pathText)")
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: expandedPath))
    }

    static func searchTheWeb(query: String) throws {
        var searchURLComponents = URLComponents(string: "https://www.google.com/search")!
        searchURLComponents.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let searchURL = searchURLComponents.url else {
            throw MacQuickActionError.invalidParameters("Busca inválida")
        }
        NSWorkspace.shared.open(searchURL)
    }

    // MARK: - Helpers

    /// AppleScript's `date "..."` parsing depends on the system locale, so
    /// dates are built field by field instead.
    private static func appleScriptLinesBuildingDate(_ date: Date, variableName: String) -> [String] {
        let dateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [
            "set \(variableName) to current date",
            // Day is set to 1 first so changing the month never overflows
            // (e.g. setting February while the current day is the 31st).
            "set day of \(variableName) to 1",
            "set year of \(variableName) to \(dateComponents.year ?? 2026)",
            "set month of \(variableName) to \(dateComponents.month ?? 1)",
            "set day of \(variableName) to \(dateComponents.day ?? 1)",
            "set hours of \(variableName) to \(dateComponents.hour ?? 9)",
            "set minutes of \(variableName) to \(dateComponents.minute ?? 0)",
            "set seconds of \(variableName) to 0"
        ]
    }

    private static func runAppleScript(_ source: String) throws {
        guard let appleScript = NSAppleScript(source: source) else {
            throw MacQuickActionError.appleScriptFailed("could not compile script")
        }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let errorMessage = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)"
            throw MacQuickActionError.appleScriptFailed(errorMessage)
        }
    }

    private static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapeForHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
