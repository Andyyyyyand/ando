//
//  ClickyHomeDesign.swift
//  leanring-buddy
//
//  Visual building blocks for the "home" panel, modeled on HeyClicky's
//  look: a near-black rounded panel, agents listed like conversations with
//  soft pastel "buddy" avatars, and glossy pill buttons.
//

import SwiftUI

enum ClickyHomeStyle {
    static let panelWidth: CGFloat = 380
    static let panelCornerRadius: CGFloat = 26
    static let panelBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let panelBorder = Color.white.opacity(0.08)
    static let rowHighlight = Color.white.opacity(0.05)
    static let divider = Color.white.opacity(0.07)
    static let titleText = Color.white.opacity(0.95)
    static let previewText = Color.white.opacity(0.5)
    static let unreadDot = Color(red: 0.25, green: 0.55, blue: 1.0)
}

// MARK: - Glossy pill buttons

enum GlossyPillVariant {
    case dark
    case light
    case blue
    case green

    var fillGradient: [Color] {
        switch self {
        case .dark: return [Color.white.opacity(0.14), Color.white.opacity(0.06)]
        case .light: return [Color.white, Color(white: 0.86)]
        case .blue: return [Color(red: 0.62, green: 0.74, blue: 1.0), Color(red: 0.36, green: 0.52, blue: 0.98)]
        case .green: return [Color(red: 0.84, green: 0.97, blue: 0.84), Color(red: 0.62, green: 0.88, blue: 0.64)]
        }
    }

    var textColor: Color {
        switch self {
        case .dark: return Color.white.opacity(0.85)
        case .light, .green: return Color.black.opacity(0.85)
        case .blue: return Color(red: 0.05, green: 0.1, blue: 0.3)
        }
    }
}

/// Rounded "liquid glass" pill: vertical gradient, bright top edge and a
/// soft drop shadow, like the buttons in the original app.
struct GlossyPillButtonStyle: ButtonStyle {
    let variant: GlossyPillVariant

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(variant.textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: variant.fillGradient, startPoint: .top, endPoint: .bottom))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.7), Color.white.opacity(0.05)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Buddy avatar

/// A soft cloud with happy "^^" eyes on a pastel disc. The colors are picked
/// from the agent's name, so each agent keeps the same face.
struct BuddyAvatarView: View {
    let seedName: String
    var size: CGFloat = 46

    private static let palettes: [(disc: Color, cloud: Color)] = [
        (Color(red: 0.78, green: 0.88, blue: 0.98), Color(red: 0.93, green: 0.62, blue: 0.55)),
        (Color(red: 0.98, green: 0.93, blue: 0.70), Color(red: 0.72, green: 0.64, blue: 0.92)),
        (Color(red: 0.98, green: 0.93, blue: 0.72), Color(red: 0.62, green: 0.80, blue: 0.97)),
        (Color(red: 0.82, green: 0.95, blue: 0.86), Color(red: 0.98, green: 0.72, blue: 0.62)),
        (Color(red: 0.95, green: 0.84, blue: 0.95), Color(red: 0.60, green: 0.78, blue: 0.95))
    ]

    private var palette: (disc: Color, cloud: Color) {
        // Stable across launches (unlike hashValue).
        let seedValue = seedName.unicodeScalars.reduce(0) { runningTotal, scalar in
            (runningTotal &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        return Self.palettes[seedValue % Self.palettes.count]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(palette.disc)

            // Cloud: three overlapping blobs
            ZStack {
                Ellipse().frame(width: size * 0.62, height: size * 0.40).offset(y: size * 0.04)
                Circle().frame(width: size * 0.34, height: size * 0.34).offset(x: -size * 0.14, y: -size * 0.04)
                Circle().frame(width: size * 0.38, height: size * 0.38).offset(x: size * 0.10, y: -size * 0.07)
            }
            .foregroundColor(palette.cloud)
            .blur(radius: size * 0.015)

            // Happy eyes
            HStack(spacing: size * 0.12) {
                HappyEyeShape().stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.12, height: size * 0.07)
                HappyEyeShape().stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.12, height: size * 0.07)
            }
            .offset(y: size * 0.01)
        }
        .frame(width: size, height: size)
    }
}

/// A "^" stroke used for the avatar's closed, smiling eyes.
private struct HappyEyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var eyePath = Path()
        eyePath.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        eyePath.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        eyePath.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return eyePath
    }
}

/// Purple-pink disc with a sparkle, used for the tips row.
struct SparkleAvatarView: View {
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.62, green: 0.45, blue: 0.95), Color(red: 0.95, green: 0.55, blue: 0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Time labels

enum ConversationTimeLabel {
    /// "14:32" today, "Ontem", a weekday within the last week, else "12/09".
    static func text(for date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "Ontem"
        }
        if let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day, daysAgo < 7 {
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date).capitalized
        }
        formatter.dateFormat = "dd/MM"
        return formatter.string(from: date)
    }
}
