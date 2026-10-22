import AppKit
import HuaciCore
import SwiftUI

/// Colors and small shared pieces of the design. Grounds, text and separators
/// use system semantic colors; only the accent and status hues are our own.
enum Theme {
    /// Indigo from the app icon.
    static let accent = dynamic(light: 0x4153D6, dark: 0x8C9BFF)
    /// Accent for text on light grounds (example highlights, phonetic pill).
    static let accentText = dynamic(light: 0x2A3AA8, dark: 0xB4BDFF)
    static let accentSoft = dynamic(light: 0xEBEDFB, dark: 0x8C9BFF, darkAlpha: 0.16)
    static let favorite = dynamic(light: 0xB86E00, dark: 0xF2B04A)
    static let success = dynamic(light: 0x1F7A5C, dark: 0x4CC38A)
    static let successDot = dynamic(light: 0x1F9D6E, dark: 0x4CC38A)
    static let successSoft = dynamic(light: 0xE6F4EE, dark: 0x4CC38A, darkAlpha: 0.16)
    static let warning = dynamic(light: 0x8F5600, dark: 0xF2B04A)
    static let warningDot = dynamic(light: 0xD98A00, dark: 0xF2B04A)
    static let warningSoft = dynamic(light: 0xFDF1E1, dark: 0xF2B04A, darkAlpha: 0.16)
    static let danger = dynamic(light: 0xB3261E, dark: 0xFF6B61)
    static let dangerSoft = dynamic(light: 0xFBE9E7, dark: 0xFF6B61, darkAlpha: 0.16)
    /// Neutral chip ground (part-of-speech badges, kind badges, skeletons).
    static let chip = dynamic(light: 0xF0F0F3, dark: 0xFFFFFF, darkAlpha: 0.08)

    static func headword(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    private static func dynamic(light: UInt32, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension TranslationService {
    /// Short name for status lines and cards.
    var shortName: String {
        switch self {
        case .personalAPI: return "个人 API"
        case .chatGPT: return "ChatGPT 账号"
        case .antigravity: return "Antigravity"
        }
    }

    var summary: String {
        switch self {
        case .personalAPI: return "OpenAI 兼容接口"
        case .chatGPT: return "使用订阅额度"
        case .antigravity: return "Google 账号额度"
        }
    }

    var symbol: String {
        switch self {
        case .personalAPI: return "key"
        case .chatGPT: return "bubble.left"
        case .antigravity: return "person.crop.circle"
        }
    }

    var usesOAuth: Bool { self != .personalAPI }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension Shortcut {
    /// One string per key cap: modifiers then the key.
    var keyCaps: [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        caps.append(Self.keyNames[keyCode] ?? "?")
        return caps
    }
}

// MARK: - Components

struct KeyCap: View {
    let text: String
    var large = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: large ? 10 : 5, style: .continuous)
        Text(text)
            .font(.system(size: large ? 24 : 13, weight: .medium))
            .frame(minWidth: large ? 52 : 24, minHeight: large ? 52 : 24)
            .padding(.horizontal, large ? 10 : 5)
            .background {
                // The bottom edge is drawn as a solid offset shape so the glyph itself casts no shadow.
                shape.fill(Color(nsColor: .separatorColor)).offset(y: large ? 3 : 1)
                shape.fill(Color(nsColor: .controlBackgroundColor))
                shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }
}

struct KeyCaps: View {
    let shortcut: Shortcut
    var large = false

    var body: some View {
        HStack(spacing: large ? 8 : 4) {
            ForEach(Array(shortcut.keyCaps.enumerated()), id: \.offset) { KeyCap(text: $0.element, large: large) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.displayString)
    }
}

struct StatusBadge: View {
    enum Tone { case success, warning, neutral }
    let text: String
    var tone: Tone = .neutral
    var dot = false
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(foreground).frame(width: 6, height: 6) }
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .neutral: return .secondary
        }
    }

    private var background: Color {
        switch tone {
        case .success: return Theme.successSoft
        case .warning: return Theme.warningSoft
        case .neutral: return Theme.chip
        }
    }
}

/// Toolbar-like button: icon, title and an optional shortcut hint, with a
/// hover ground.
struct ActionButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        HoverBackground(pressed: configuration.isPressed) {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(tint)
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBackground(pressed: configuration.isPressed, active: active, horizontalPadding: 0) {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Theme.accent : .secondary)
                .frame(width: size, height: size)
        }
    }
}

private struct HoverBackground<Content: View>: View {
    var pressed: Bool
    var active = false
    var horizontalPadding: CGFloat = 10
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: 28)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var fill: Color {
        if active { return Theme.accentSoft }
        if pressed { return Color.primary.opacity(0.12) }
        return hovering ? Color.primary.opacity(0.07) : .clear
    }
}

struct ShortcutHint: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

/// Placeholder bar shown while a result loads; pulses on a timeline so the
/// surrounding layout never animates.
struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 12

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * .pi / 0.9
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.chip)
                .opacity(0.78 + 0.22 * cos(phase))
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// Grouped-form footnote style text.
struct Footnote: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
