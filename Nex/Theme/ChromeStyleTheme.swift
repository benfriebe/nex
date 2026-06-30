import Foundation

/// A shareable bundle of the user's custom chrome styling: the per-appearance
/// colour overrides (both the light *and* dark buckets), the sidebar colour
/// intensity / fill-stroke opacities, and the sparkline styling. Serialises to
/// a `.nextheme` JSON file or a single-line copy-pasteable code, so a look can
/// be shared between installs.
///
/// Deliberately excludes the recipient's light/dark mode and terminal
/// background: importing a theme restyles the chrome without forcing those.
struct ChromeStyleTheme: Codable, Equatable {
    /// Bumped when the serialised shape changes incompatibly. Decoders reject a
    /// version newer than they understand rather than silently dropping fields.
    static let currentVersion = 1

    /// Prefix on the share-code form so a pasted blob is recognisable and can be
    /// stripped before base64-decoding.
    static let codePrefix = "nex-theme:"

    var version: Int
    /// Optional label (the file name on export); echoed back on import.
    var name: String?

    /// `"<light|dark>:<ChromeColorKey>"` → `"RRGGBB"`, carrying both buckets.
    var colorOverrides: [String: String]

    var sidebarColorIntensity: Double
    var sidebarAvatarFillOpacity: Double
    var sidebarAvatarStrokeOpacity: Double
    var sidebarGroupFillOpacity: Double
    var sidebarGroupStrokeOpacity: Double

    var sparklineColorHex: String
    var sparklineWidth: Double
    var sparklineStyle: String
}

extension ChromeStyleTheme {
    // MARK: - File form (pretty JSON)

    /// Pretty-printed JSON for the `.nextheme` file form.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Decode from `.nextheme` (or any theme JSON) data, rejecting a version
    /// produced by a newer Nex than this one understands.
    init(jsonData data: Data) throws {
        let decoded = try JSONDecoder().decode(ChromeStyleTheme.self, from: data)
        guard decoded.version <= Self.currentVersion else {
            throw ChromeStyleThemeError.unsupportedVersion(decoded.version)
        }
        self = decoded
    }

    // MARK: - Code form (prefixed base64 of compact JSON)

    /// A single-line, copy-pasteable code: `nex-theme:<base64(compact JSON)>`.
    func shareCode() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return Self.codePrefix + data.base64EncodedString()
    }

    /// Decode from a share code. Accepts the prefixed base64 form, a bare
    /// base64 blob, or the raw JSON file contents pasted directly — so any
    /// export form round-trips. Anything else throws `invalidCode`.
    init(shareCode code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = trimmed
        if body.hasPrefix(Self.codePrefix) {
            body.removeFirst(Self.codePrefix.count)
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: body) {
            try self.init(jsonData: data)
            return
        }
        if trimmed.first == "{", let data = trimmed.data(using: .utf8) {
            try self.init(jsonData: data)
            return
        }
        throw ChromeStyleThemeError.invalidCode
    }
}

enum ChromeStyleThemeError: Error, Equatable {
    case invalidCode
    case unsupportedVersion(Int)

    /// User-facing message for the Settings status line.
    var message: String {
        switch self {
        case .invalidCode:
            "That doesn't look like a Nex theme."
        case .unsupportedVersion(let version):
            "This theme was made with a newer version of Nex (v\(version))."
        }
    }
}
