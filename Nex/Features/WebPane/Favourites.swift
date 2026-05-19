import Foundation

struct Favourite: Equatable, Identifiable, Codable {
    let id: UUID
    var url: String
    var title: String
    let createdAt: Date

    init(id: UUID = UUID(), url: String, title: String = "", createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
    }

    /// Falls back through title -> host -> raw url so a favourite
    /// captured before a page title arrives still shows something.
    var displayLabel: String {
        if !title.isEmpty { return title }
        if let host = URL(string: url)?.host, !host.isEmpty { return host }
        return url
    }
}

enum FavouritesStorage {
    static let defaultsKey = "web.favourites"

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func decode(_ json: String?) -> [Favourite] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        return (try? decoder.decode([Favourite].self, from: data)) ?? []
    }

    static func encode(_ favourites: [Favourite]) -> String {
        guard let data = try? encoder.encode(favourites),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

extension [Favourite] {
    /// Match by URL, normalising only the parts that are
    /// case-insensitive by spec (scheme + host) and stripping trailing
    /// slashes. Paths and query strings stay case-sensitive — most
    /// servers treat `/API` and `/api` as different resources.
    func firstMatching(url: String) -> Favourite? {
        let needle = Self.normalised(url)
        return first { Self.normalised($0.url) == needle }
    }

    fileprivate static func normalised(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        var stripped: String
        if var comps = URLComponents(string: trimmed) {
            comps.scheme = comps.scheme?.lowercased()
            comps.host = comps.host?.lowercased()
            stripped = comps.string ?? trimmed
        } else {
            stripped = trimmed
        }
        while stripped.hasSuffix("/") {
            stripped.removeLast()
        }
        return stripped
    }
}
