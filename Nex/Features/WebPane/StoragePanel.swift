import SwiftUI
import WebKit

/// Disclosure panel below the URL bar that exposes the per-pane
/// storage controls: a private-mode toggle and a list of cookies for
/// the active data store. Mirrors the visual treatment of the
/// element-pickup panel — same border / background, same compact
/// footer-row Send-style buttons.
///
/// Read/delete go through the pane's coordinator's
/// `dataStore.httpCookieStore`. The toggle goes through `onTogglePrivate`
/// up to the reducer, which warns the user before flipping the flag
/// (toggling between persistent + nonPersistent stores forces a
/// coordinator rebuild and loses live JS state).
struct StoragePanel: View {
    let paneID: UUID
    let isPrivate: Bool
    let onTogglePrivate: () -> Void
    let onClose: () -> Void

    @Environment(\.webPaneStore) private var webPaneStore

    @State private var cookies: [HTTPCookie] = []
    /// Grouped + sorted view of `cookies`. Cached in @State so body
    /// invalidations driven by unrelated edits (e.g. typing in an
    /// inline edit form) don't redo the O(n log n) grouping.
    @State private var groupedCookies: [CookieDomainGroup] = []
    @State private var isLoading: Bool = false
    @State private var showingToggleConfirm: Bool = false
    @State private var showingClearAllConfirm: Bool = false
    /// Domains whose accordion is open. Default closed — keeps the
    /// panel compact when sites pile up.
    @State private var expandedDomains: Set<String> = []
    /// Canonical identity (`domain|path|name`) of the cookie whose
    /// inline edit form is open. nil = no edit form.
    @State private var editingKey: String?
    /// Non-nil while an inline create form is open. The string is the
    /// pre-filled domain (empty = the top-level "any domain" form).
    @State private var addingDomain: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            privateToggleRow

            Divider().opacity(0.5)

            cookiesSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .onAppear(perform: refreshCookies)
        .confirmationDialog(
            isPrivate
                ? "Disable private mode for this pane?"
                : "Enable private mode for this pane?",
            isPresented: $showingToggleConfirm,
            titleVisibility: .visible
        ) {
            Button(isPrivate ? "Disable private mode" : "Enable private mode", role: .destructive) {
                onTogglePrivate()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(toggleConfirmMessage)
        }
        .confirmationDialog(
            "Clear all site data for this pane?",
            isPresented: $showingClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all site data", role: .destructive) {
                clearAllSiteData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes cookies, local storage, IndexedDB, and caches. Logged-in sessions on this data store will be signed out.")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isPrivate ? "lock.fill" : "lock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isPrivate ? Color.accentColor : Color.secondary)
            Text("Storage")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close storage panel")
        }
    }

    private var privateToggleRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Private mode")
                    .font(.system(size: 11, weight: .medium))
                Text(isPrivate
                    ? "Cookies + caches discarded on quit; tabs blank on restart."
                    : "Cookies + caches persist across restarts.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isPrivate },
                set: { _ in showingToggleConfirm = true }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var cookiesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Cookies")
                    .font(.system(size: 11, weight: .medium))
                Text(cookies.isEmpty ? "" : "(\(cookies.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
                Spacer()
                Button(action: { beginAdd(forDomain: "") }) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a cookie")

                Button(action: refreshCookies) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh cookie list")

                Button(role: .destructive, action: { showingClearAllConfirm = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.85))
                .help("Clear all site data (cookies, caches, local storage)")
            }

            // Top-level create form for a brand new domain. Opens
            // above the domain list so the user sees their input near
            // the trigger.
            if addingDomain == "" {
                CookieEditForm(
                    initial: .blank(),
                    allowDomainEdit: true,
                    onSave: { draft in
                        save(draft: draft, replacing: nil)
                    },
                    onCancel: { addingDomain = nil }
                )
                .padding(.vertical, 4)
            }

            if cookies.isEmpty, addingDomain == nil {
                Text(isPrivate
                    ? "No cookies (private mode — fresh on every launch)."
                    : "No cookies for this data store yet.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else if !cookies.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedCookies, id: \.domain) { group in
                            cookieDomainGroup(group)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func cookieDomainGroup(_ group: CookieDomainGroup) -> some View {
        let isOpen = expandedDomains.contains(group.domain)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button(action: { toggleExpanded(group.domain) }) {
                    HStack(spacing: 4) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .frame(width: 10)
                            .foregroundStyle(.secondary)
                        Text(group.domain)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                        Text("(\(group.cookies.count))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: { beginAdd(forDomain: group.domain) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add cookie for \(group.domain)")

                Button(role: .destructive, action: { delete(cookies: group.cookies) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 8))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.75))
                .help("Delete all cookies for \(group.domain)")
            }
            .padding(.top, 4)
            .padding(.bottom, 2)

            if isOpen {
                if addingDomain == group.domain {
                    CookieEditForm(
                        initial: .blank(domain: group.domain),
                        allowDomainEdit: false,
                        onSave: { draft in save(draft: draft, replacing: nil) },
                        onCancel: { addingDomain = nil }
                    )
                    .padding(.leading, 14)
                    .padding(.vertical, 4)
                }
                ForEach(group.cookies, id: \.self) { cookie in
                    cookieRow(cookie)
                }
            }
        }
    }

    private func cookieRow(_ cookie: HTTPCookie) -> some View {
        let key = Self.cookieKey(cookie)
        let isEditing = editingKey == key
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button(action: { toggleEditing(key) }) {
                    HStack(spacing: 4) {
                        Image(systemName: isEditing ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .frame(width: 10)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(cookie.name)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                            Text(Self.truncatedValue(cookie.value))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button(role: .destructive, action: { delete(cookies: [cookie]) }) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 9))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete cookie \(cookie.name)")
            }
            .padding(.leading, 14)
            .padding(.vertical, 1)

            if isEditing {
                CookieEditForm(
                    initial: .from(cookie: cookie),
                    allowDomainEdit: false,
                    onSave: { draft in save(draft: draft, replacing: cookie) },
                    onCancel: { editingKey = nil },
                    onDelete: { delete(cookies: [cookie]); editingKey = nil }
                )
                .padding(.leading, 24)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
            }
        }
    }

    private var toggleConfirmMessage: String {
        if isPrivate {
            return "Tabs will reload against the persistent store. Live JS state will be lost; previously-saved cookies become visible again."
        }
        return "Tabs will reload in a non-persistent session. Live JS state will be lost; cookies created in private mode are discarded on quit."
    }

    // MARK: - Cookie I/O

    private struct CookieDomainGroup {
        let domain: String
        let cookies: [HTTPCookie]
    }

    private static func buildGroups(from cookies: [HTTPCookie]) -> [CookieDomainGroup] {
        let grouped = Dictionary(grouping: cookies, by: { HTTPCookie.canonicalDomain($0.domain) })
        return grouped
            .map { CookieDomainGroup(domain: $0.key, cookies: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.domain < $1.domain }
    }

    private func refreshCookies() {
        guard let coord = webPaneStore.coordinatorIfExists(for: paneID) else {
            cookies = []
            groupedCookies = []
            return
        }
        isLoading = true
        coord.dataStore.httpCookieStore.getAllCookies { fetched in
            cookies = fetched
            groupedCookies = Self.buildGroups(from: fetched)
            isLoading = false
        }
    }

    private func delete(cookies toDelete: [HTTPCookie]) {
        guard let coord = webPaneStore.coordinatorIfExists(for: paneID) else { return }
        let store = coord.dataStore.httpCookieStore
        var remaining = toDelete.count
        guard remaining > 0 else { return }
        for cookie in toDelete {
            store.delete(cookie) {
                remaining -= 1
                if remaining == 0 {
                    refreshCookies()
                }
            }
        }
    }

    private func clearAllSiteData() {
        guard let coord = webPaneStore.coordinatorIfExists(for: paneID) else { return }
        let store = coord.dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: types, modifiedSince: .distantPast) {
            refreshCookies()
        }
    }

    private func toggleExpanded(_ domain: String) {
        if expandedDomains.contains(domain) {
            expandedDomains.remove(domain)
        } else {
            expandedDomains.insert(domain)
        }
    }

    private func toggleEditing(_ key: String) {
        editingKey = (editingKey == key) ? nil : key
        // Editing and adding are mutually exclusive — collapsing one
        // when the other opens keeps the panel readable.
        if editingKey != nil {
            addingDomain = nil
        }
    }

    private func beginAdd(forDomain domain: String) {
        addingDomain = domain
        editingKey = nil
        if !domain.isEmpty {
            expandedDomains.insert(domain)
        }
    }

    /// Build an `HTTPCookie` from form input and persist it. If
    /// `replacing` is non-nil, the original cookie is deleted first
    /// (RFC 6265 identity is `domain|path|name` — when those don't
    /// change WebKit replaces the value in place; we delete-then-set
    /// unconditionally so a renamed cookie doesn't leave the old one
    /// behind).
    private func save(draft: CookieDraft, replacing existing: HTTPCookie?) {
        guard let coord = webPaneStore.coordinatorIfExists(for: paneID) else { return }
        let cookieStore = coord.dataStore.httpCookieStore

        // HTTPCookie(properties:) treats `.secure` / HttpOnly as truthy
        // whenever the key is present, regardless of value, so omit them
        // unless they should be on.
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: draft.name,
            .value: draft.value,
            .domain: draft.domain,
            .path: draft.path.isEmpty ? "/" : draft.path
        ]
        if draft.isSecure {
            props[.secure] = "TRUE"
        }
        if draft.isHTTPOnly {
            props[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE"
        }
        if let expires = draft.expires {
            props[.expires] = expires
        }
        guard let cookie = HTTPCookie(properties: props) else {
            // Invalid combination (e.g. domain didn't validate).
            // Surface a console log so an inspector run can pick it up.
            NSLog("[StoragePanel] HTTPCookie(properties:) returned nil for draft: \(draft)")
            return
        }

        let finish: () -> Void = {
            cookieStore.setCookie(cookie) {
                editingKey = nil
                addingDomain = nil
                refreshCookies()
            }
        }
        if let existing {
            cookieStore.delete(existing, completionHandler: finish)
        } else {
            finish()
        }
    }

    // MARK: - Helpers

    private static func truncatedValue(_ value: String, max: Int = 60) -> String {
        if value.count <= max { return value }
        return String(value.prefix(max - 1)) + "…"
    }

    /// Stable identity for inline-edit state. RFC 6265 disambiguates
    /// cookies by (domain, path, name); two cookies with the same name
    /// on different paths are distinct, so include all three.
    private static func cookieKey(_ cookie: HTTPCookie) -> String {
        "\(cookie.domain)|\(cookie.path)|\(cookie.name)"
    }
}

// MARK: - Cookie draft + edit form

/// Editable cookie shape. Mirrors the subset of HTTPCookie fields
/// the inline form exposes — name / value / domain / path / secure
/// / expires. `isHTTPOnly` is preserved through edits but not
/// user-editable (browser cookies set HttpOnly server-side; a UI
/// toggle is debug-only and easy to mis-set).
struct CookieDraft: Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var isSecure: Bool
    /// Carried from the source cookie so a save() that delete+recreates
    /// doesn't silently strip HttpOnly. Not user-editable from the form.
    var isHTTPOnly: Bool
    /// nil = session cookie (no Expires header). Hidden behind a
    /// "Session only" toggle in the form.
    var expires: Date?

    static func blank(domain: String = "") -> CookieDraft {
        CookieDraft(
            name: "",
            value: "",
            domain: domain,
            path: "/",
            isSecure: false,
            isHTTPOnly: false,
            expires: nil
        )
    }

    static func from(cookie: HTTPCookie) -> CookieDraft {
        CookieDraft(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly,
            expires: cookie.expiresDate
        )
    }
}

private struct CookieEditForm: View {
    let initial: CookieDraft
    let allowDomainEdit: Bool
    let onSave: (CookieDraft) -> Void
    let onCancel: () -> Void
    var onDelete: (() -> Void)?

    @State private var draft: CookieDraft
    @State private var isSessionCookie: Bool
    @State private var expires: Date

    init(
        initial: CookieDraft,
        allowDomainEdit: Bool,
        onSave: @escaping (CookieDraft) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.initial = initial
        self.allowDomainEdit = allowDomainEdit
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _draft = State(initialValue: initial)
        _isSessionCookie = State(initialValue: initial.expires == nil)
        // Pre-fill the date picker even for session cookies so flipping
        // the toggle off shows something sensible (30 days from now).
        _expires = State(initialValue: initial.expires
            ?? Date().addingTimeInterval(30 * 24 * 60 * 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            field(label: "Name", text: Binding(
                get: { draft.name },
                set: { draft.name = $0 }
            ))
            field(label: "Value", text: Binding(
                get: { draft.value },
                set: { draft.value = $0 }
            ))
            field(label: "Domain", text: Binding(
                get: { draft.domain },
                set: { draft.domain = $0 }
            ), disabled: !allowDomainEdit)
            field(label: "Path", text: Binding(
                get: { draft.path },
                set: { draft.path = $0 }
            ))
            HStack(spacing: 12) {
                Toggle("Secure", isOn: Binding(
                    get: { draft.isSecure },
                    set: { draft.isSecure = $0 }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Toggle("Session only", isOn: $isSessionCookie)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            .font(.system(size: 10))

            if !isSessionCookie {
                HStack(spacing: 6) {
                    Text("Expires")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                    DatePicker("", selection: $expires)
                        .datePickerStyle(.compact)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }

            HStack(spacing: 6) {
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Text("Delete")
                            .font(.system(size: 10))
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
                Button("Save", action: commit)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.domain.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func commit() {
        var out = draft
        out.name = out.name.trimmingCharacters(in: .whitespaces)
        out.domain = out.domain.trimmingCharacters(in: .whitespaces)
        out.path = out.path.trimmingCharacters(in: .whitespaces)
        out.expires = isSessionCookie ? nil : expires
        guard isValid else { return }
        onSave(out)
    }

    private func field(
        label: String,
        text: Binding<String>,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
            TextField("", text: text)
                .font(.system(size: 10, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .disabled(disabled)
                .opacity(disabled ? 0.6 : 1.0)
        }
    }
}

extension HTTPCookie {
    /// Drops a single leading `.` so RFC-style `.example.com` matches
    /// `example.com` for grouping + filtering.
    static func canonicalDomain(_ domain: String) -> String {
        domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    }
}

extension WKHTTPCookieStore {
    /// Fetches all cookies, deletes those matching `predicate`, and
    /// invokes `completion` with the deleted count once every delete
    /// completion has fired.
    func deleteAll(
        matching predicate: @escaping (HTTPCookie) -> Bool,
        completion: @escaping (Int) -> Void
    ) {
        getAllCookies { cookies in
            let matches = cookies.filter(predicate)
            if matches.isEmpty {
                completion(0)
                return
            }
            var remaining = matches.count
            let total = matches.count
            for cookie in matches {
                self.delete(cookie) {
                    remaining -= 1
                    if remaining == 0 {
                        completion(total)
                    }
                }
            }
        }
    }
}
