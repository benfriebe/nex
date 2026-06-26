import AppKit
import Foundation
import SwiftUI

/// The colour of a label preset: either one of the eight named workspace
/// colours, or an arbitrary custom colour stored as a `#RRGGBB` hex.
///
/// Persisted as a single string — a `WorkspaceColor` raw value
/// (`"blue"`) for named colours, or a hex (`"#ff8800"`) for custom ones.
/// Decoding picks `.named` when the string matches a `WorkspaceColor`,
/// otherwise `.custom`, so existing `"color":"blue"` data keeps working.
enum LabelColor: Equatable, Hashable {
    case named(WorkspaceColor)
    case custom(String)

    /// SwiftUI colour for rendering. A malformed custom hex falls back to
    /// gray rather than crashing.
    var color: Color {
        switch self {
        case .named(let workspaceColor): workspaceColor.color
        case .custom(let hex): Color(hex: hex) ?? .gray
        }
    }

    /// A `#RRGGBB` hex for this colour, used to seed the custom colour
    /// picker when switching a named colour to custom.
    var hex: String {
        switch self {
        case .named(let workspaceColor): workspaceColor.color.hexString
        case .custom(let hex): hex
        }
    }

    /// The named case, or nil when custom. Drives the dropdown's
    /// checkmark and the "Custom" label.
    var namedColor: WorkspaceColor? {
        if case .named(let workspaceColor) = self { return workspaceColor }
        return nil
    }
}

extension LabelColor: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let workspaceColor = WorkspaceColor(rawValue: raw) {
            self = .named(workspaceColor)
        } else {
            self = .custom(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .named(let workspaceColor): try container.encode(workspaceColor.rawValue)
        case .custom(let hex): try container.encode(hex)
        }
    }
}

/// A user-defined workspace label preset: a name paired with a colour.
///
/// Presets are a global, app-level convenience — picking one in the
/// inspector adds its `name` to a workspace's free-form `labels` (the
/// existing string list is unchanged), and chips whose text matches a
/// preset name render in the preset's colour. Identity is the name, which
/// is unique (case-sensitive) within the preset list. This mirrors how a
/// label string matches a preset: exact, case-sensitive (labels are only
/// trimmed/clamped by `WorkspaceFeature.normalizeLabel`, never lowercased).
struct LabelPreset: Equatable, Identifiable, Codable {
    var name: String
    var color: LabelColor
    /// Explicit text colour for the chip, or nil to auto-pick black/white
    /// by the background's luminance. Lets a user fix a colour where the
    /// auto choice is still hard to read.
    var textColor: LabelColor?

    var id: String { name }

    init(name: String, color: LabelColor, textColor: LabelColor? = nil) {
        self.name = name
        self.color = color
        self.textColor = textColor
    }
}

/// A label's resolved on-screen colours: the solid chip background and the
/// text colour (an explicit override, or auto black/white by contrast).
struct ResolvedLabelStyle: Equatable {
    var background: Color
    var text: Color
}

extension LabelPreset {
    var resolvedStyle: ResolvedLabelStyle {
        let background = color.color
        return ResolvedLabelStyle(
            background: background,
            text: textColor?.color ?? background.contrastingText
        )
    }
}

extension [LabelPreset] {
    /// Colour for a label string via exact, case-sensitive name match, or
    /// nil when no preset matches (the chip renders neutral).
    func color(for label: String) -> LabelColor? {
        first { $0.name == label }?.color
    }
}

/// JSON-in-UserDefaults persistence for the label preset list, mirroring
/// `FavouritesStorage`. Presets are a flat, foreign-key-free global list,
/// so they live alongside favourites in UserDefaults rather than in the
/// GRDB entity graph.
enum LabelPresetsStorage {
    static let defaultsKey = "settings.labelPresets"

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func decode(_ json: String?) -> [LabelPreset] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        return (try? decoder.decode([LabelPreset].self, from: data)) ?? []
    }

    static func encode(_ presets: [LabelPreset]) -> String {
        guard let data = try? encoder.encode(presets),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

extension Color {
    /// Parse a `#RRGGBB` (or `RRGGBB`) hex string. Returns nil for any
    /// other length/format so callers can fall back.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit),
              let value = UInt32(s, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: red, green: green, blue: blue)
    }

    /// `#RRGGBB` hex for this colour, resolved through sRGB.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let red = Int((ns.redComponent * 255).rounded())
        let green = Int((ns.greenComponent * 255).rounded())
        let blue = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", red, green, blue)
    }

    /// Perceived (sRGB-weighted) luminance, 0 (black) … 1 (white).
    private var srgbLuminance: Double {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return 0.299 * Double(ns.redComponent)
            + 0.587 * Double(ns.greenComponent)
            + 0.114 * Double(ns.blueComponent)
    }

    /// Black or white text, whichever reads better on a solid fill of this
    /// colour. Used for the GitHub-style solid label chips.
    var contrastingText: Color {
        srgbLuminance > 0.6 ? .black : .white
    }

    /// A non-template swatch image for showing a real colour inside a macOS
    /// `Menu`: SF Symbols are templated (monochrome) in menus, so a coloured
    /// dot drawn as a non-template `NSImage` is the reliable way to show
    /// true colours. Draws a white/black checkmark when `checked`.
    func menuSwatch(diameter: CGFloat = 11, checked: Bool = false) -> Image {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        // Pull out Sendable components so the drawing closure captures no
        // non-Sendable NSColor (Swift 6 strict concurrency).
        let red = ns.redComponent, green = ns.greenComponent, blue = ns.blueComponent
        let dark = (0.299 * red + 0.587 * green + 0.114 * blue) > 0.6
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).setFill()
            circle.fill()
            NSColor(white: 0.5, alpha: 0.4).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            if checked {
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: rect.width * 0.28, y: rect.height * 0.50))
                mark.line(to: NSPoint(x: rect.width * 0.43, y: rect.height * 0.34))
                mark.line(to: NSPoint(x: rect.width * 0.72, y: rect.height * 0.68))
                mark.lineWidth = 1.5
                mark.lineCapStyle = .round
                mark.lineJoinStyle = .round
                NSColor(white: dark ? 0 : 1, alpha: 1).setStroke()
                mark.stroke()
            }
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}
