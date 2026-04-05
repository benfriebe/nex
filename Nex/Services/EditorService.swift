import ComposableArchitecture
import Darwin
import Foundation

/// Resolves the user's preferred text editor and builds launch commands for it.
///
/// On macOS, GUI applications don't inherit the shell's environment, so
/// `ProcessInfo.environment["EDITOR"]` is almost always empty for a `.app`
/// launched from Finder or Dock. Worse, `ProcessInfo.environment["SHELL"]`
/// is often empty too, which would cause a naive implementation to fall back
/// to `/bin/sh` and miss the user's zsh rc files.
///
/// We work around both problems by reading the user's login shell directly
/// from the directory services passwd database (`getpwuid(3)`) — the same
/// technique ghostty uses (`ghostty/src/os/passwd.zig`) — then invoking it
/// with `-l -i -c` so both login and interactive rc files are sourced. This
/// covers bash users who put `$EDITOR` in `.bashrc` (interactive-only) and
/// zsh users who put it in `.zshrc` (interactive-only) or `.zprofile`
/// (login-only). POSIX convention: `$VISUAL` wins over `$EDITOR`.
///
/// Resolution happens once at warmup time (on a background queue) and
/// captures both the editor string *and* the user's full `$PATH`. At launch
/// time we don't wrap the editor in another login shell — ghostty already
/// wraps commands in `/bin/sh -c` (see `ghostty/src/apprt/embedded.zig`
/// line ~445), and we just inject PATH inline so that fast shell can find
/// the editor binary. Skipping the nested `zsh -l -i` avoids 1–2 seconds of
/// rc-file loading on every ⌘E press.
struct EditorService {
    /// Returns the resolved editor command (e.g. `"nvim"`, `"code -w"`),
    /// or nil if resolution hasn't completed yet or no editor is set.
    /// **Non-blocking**: if resolution is still in progress, returns nil
    /// immediately so callers can fall back without stalling.
    var resolveEditor: @Sendable () -> String?

    /// Returns a command string suitable for `ghostty_surface_config_s.command`
    /// that launches the user's editor on the given file, or nil if no editor
    /// is resolvable (or resolution is still pending). The command is a plain
    /// `PATH='…' editor 'file'` invocation that ghostty's internal
    /// `/bin/sh -c` can execute directly — no nested login shell.
    /// **Non-blocking** — see `resolveEditor`.
    var buildCommand: @Sendable (_ filePath: String) -> String?

    /// Kick off background resolution of the user's `$VISUAL` / `$EDITOR`
    /// and `$PATH`. Safe to call multiple times; subsequent calls are no-ops.
    /// Call once at app launch so the cache is warm by the time the user
    /// first presses ⌘E on a markdown pane.
    var warmUp: @Sendable () -> Void
}

// MARK: - Live Implementation

extension EditorService {
    static let live: EditorService = {
        let cache = EditorResolutionCache()

        return EditorService(
            resolveEditor: { cache.currentValue()?.editor },
            buildCommand: { filePath in
                guard let resolved = cache.currentValue() else { return nil }
                return formatCommand(
                    editor: resolved.editor,
                    filePath: filePath,
                    loginPath: resolved.path
                )
            },
            warmUp: { cache.warmUp() }
        )
    }()

    /// Escape a string for embedding inside single quotes in a POSIX shell.
    /// Each literal single quote becomes `'\''` (close-quote, escaped quote, reopen-quote).
    static func singleQuoteEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Build the command string ghostty will hand to `/bin/sh -c` at launch.
    /// When `loginPath` is non-nil, run the editor via `/usr/bin/env PATH=…`
    /// so the editor is findable even in the minimal environment a `.app`
    /// bundle gets from LaunchServices.
    ///
    /// We can't use the simpler `PATH='…' editor 'file'` form because on
    /// macOS ghostty wraps the command as `bash -c "exec -l <command>"`
    /// (see `ghostty/src/termio/Exec.zig` line 1524), and bash's `exec`
    /// builtin treats its first argument as a program name rather than
    /// parsing `VAR=value` as a simple-command assignment. `env` is a real
    /// program, so `exec -l env PATH=… editor 'file'` works cleanly.
    /// Exposed as a pure function for tests.
    static func formatCommand(editor: String, filePath: String, loginPath: String?) -> String {
        let escapedFile = singleQuoteEscape(filePath)
        guard let loginPath, !loginPath.isEmpty else {
            return "\(editor) '\(escapedFile)'"
        }
        let escapedPath = singleQuoteEscape(loginPath)
        return "/usr/bin/env PATH='\(escapedPath)' \(editor) '\(escapedFile)'"
    }

    /// Return the user's login shell path. Reads the passwd database via
    /// `getpwuid(3)`, which is reliable even for `.app` bundles launched
    /// from Finder/Dock (unlike `$SHELL`, which is often empty in GUI env).
    /// Falls back to `$SHELL`, then `/bin/sh`.
    static func resolveUserShell() -> String {
        if let pwPtr = getpwuid(getuid()),
           let shellPtr = pwPtr.pointee.pw_shell {
            let shell = String(cString: shellPtr)
            if !shell.isEmpty { return shell }
        }
        if let envShell = ProcessInfo.processInfo.environment["SHELL"],
           !envShell.isEmpty {
            return envShell
        }
        return "/bin/sh"
    }

    /// Sentinel lines bracketing the `printf` output so we can extract
    /// VISUAL/EDITOR/PATH out of an arbitrarily noisy shell init. `.zshrc`
    /// and `.bashrc` often print banners, `last login`, `gitstatus` debug,
    /// `direnv: loading …`, etc., which would otherwise shift a positional
    /// parse off the rails.
    static let shellOutputBeginMarker = "__NEX_EDITOR_BEGIN__"
    static let shellOutputEndMarker = "__NEX_EDITOR_END__"

    /// Extract VISUAL, EDITOR, and PATH from a shell subprocess's stdout.
    /// Searches for `shellOutputBeginMarker`, then takes the next three
    /// lines as the values. If the marker is missing (the shell exited
    /// before `printf` ran, or was killed by the watchdog mid-init), all
    /// fields come back empty.
    static func parseShellOutput(_ output: String) -> (visual: String, editor: String, path: String) {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let beginIdx = lines.firstIndex(of: shellOutputBeginMarker) else {
            return ("", "", "")
        }
        func lineAt(_ offset: Int) -> String {
            let idx = beginIdx + offset
            guard idx < lines.count else { return "" }
            let line = lines[idx].trimmingCharacters(in: .whitespaces)
            // Don't mistake the end marker for a value.
            return line == shellOutputEndMarker ? "" : line
        }
        return (visual: lineAt(1), editor: lineAt(2), path: lineAt(3))
    }
}

// MARK: - Resolution cache

/// One editor resolution: the raw editor command plus the login shell's
/// `$PATH`, captured once so the launch step can skip a full shell init.
struct EditorResolution: Equatable {
    let editor: String
    let path: String?
}

/// Thread-safe `Data` accumulator used by `queryShell` to drain a pipe
/// from a background `readabilityHandler` while the caller also appends
/// a final flush after `waitUntilExit`.
private final class ConcurrentDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Thread-safe, non-blocking resolver. Resolution runs once on a background
/// queue; callers never block the reducer. Until resolution finishes,
/// `currentValue()` returns nil and callers should fall back (e.g., the
/// built-in editor). After resolution, the cached value is served synchronously.
private final class EditorResolutionCache: @unchecked Sendable {
    private enum State {
        case notStarted
        case resolving
        case resolved(EditorResolution?, at: Date)
    }

    /// How long to hold on to a *failed* resolution before retrying.
    /// Successes are cached for the app's lifetime; failures get a TTL so a
    /// one-off watchdog timeout, slow cold-cache shell init, or transient
    /// error doesn't permanently disable the external-editor path.
    private static let failureRetryInterval: TimeInterval = 30.0

    private let lock = NSLock()
    private var state: State = .notStarted

    /// Returns the resolved editor if already available, otherwise nil. Kicks
    /// off background resolution on first call. Never blocks the caller.
    func currentValue() -> EditorResolution? {
        lock.lock()
        switch state {
        case .resolved(let value, let timestamp):
            if value != nil {
                lock.unlock()
                return value
            }
            // Recent failure — fall back without re-spawning the shell.
            if Date().timeIntervalSince(timestamp) < Self.failureRetryInterval {
                lock.unlock()
                return nil
            }
            // Stale failure — retry in the background.
            state = .resolving
            lock.unlock()
            startBackgroundResolution()
            return nil
        case .resolving:
            lock.unlock()
            return nil
        case .notStarted:
            state = .resolving
            lock.unlock()
            startBackgroundResolution()
            return nil
        }
    }

    /// Start background resolution if not already started. Idempotent.
    /// Call at app launch so the cache is warm before the user's first ⌘E.
    func warmUp() {
        _ = currentValue()
    }

    private func startBackgroundResolution() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let value = Self.queryShell() ?? Self.queryEnvironment()
            lock.lock()
            state = .resolved(value, at: Date())
            lock.unlock()
        }
    }

    /// Run the user's shell in login+interactive mode to read `$VISUAL`,
    /// `$EDITOR`, and `$PATH` from their rc files.
    ///
    /// Two failure modes we explicitly guard against:
    /// 1. **Noisy shell init.** `.zshrc` / `.bashrc` frequently print
    ///    banners, `gitstatus` debug, `direnv: loading …`, MOTDs, etc.,
    ///    which would shift a positional line-parse off the rails. We
    ///    bracket our `printf` output with sentinel markers and scan for
    ///    them, so the values survive arbitrary init noise.
    /// 2. **Pipe buffer deadlock.** Each stdio pipe has a ~64KB kernel
    ///    buffer; if shell init writes more than that and we only read
    ///    after `waitUntilExit()`, the child blocks on `write(2)` and the
    ///    watchdog has to kill it. We drain both pipes concurrently via
    ///    `readabilityHandler` so they never fill.
    ///
    /// A 2s watchdog terminates the shell if it still hangs for any other
    /// reason. `-l -i` is required so `.zshrc` / `.bashrc` are sourced
    /// (where most users actually set `$EDITOR`).
    private static func queryShell() -> EditorResolution? {
        let shellPath = EditorService.resolveUserShell()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        let beginMarker = EditorService.shellOutputBeginMarker
        let endMarker = EditorService.shellOutputEndMarker
        process.arguments = [
            "-l", "-i", "-c",
            #"printf '\n%s\n%s\n%s\n%s\n%s\n' "\#(beginMarker)" "$VISUAL" "$EDITOR" "$PATH" "\#(endMarker)""#
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes concurrently. A chatty init script (>64KB) would
        // otherwise block the shell on write and force the watchdog to kill
        // it. We keep stdout; stderr is read but discarded.
        let stdoutBuffer = ConcurrentDataBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.append(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: watchdog)

        do {
            try process.run()
        } catch {
            watchdog.cancel()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            print("EditorService: failed to spawn \(shellPath) — \(error)")
            return nil
        }
        process.waitUntilExit()
        watchdog.cancel()

        // Pick up anything buffered between the last handler fire and exit,
        // then detach handlers so the pipes can be deallocated.
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.availableData)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            print("EditorService: \(shellPath) exited with status \(process.terminationStatus)")
            return nil
        }

        let output = String(data: stdoutBuffer.snapshot(), encoding: .utf8) ?? ""
        let parsed = EditorService.parseShellOutput(output)
        let chosen = !parsed.visual.isEmpty
            ? parsed.visual
            : (!parsed.editor.isEmpty ? parsed.editor : nil)
        guard let chosen else {
            print("EditorService: \(shellPath) produced no $VISUAL or $EDITOR")
            return nil
        }
        print("EditorService: resolved editor='\(chosen)' via \(shellPath)")
        return EditorResolution(
            editor: chosen,
            path: parsed.path.isEmpty ? nil : parsed.path
        )
    }

    /// Fallback to this process's own environment. Unlikely to succeed for a
    /// GUI launch, but covers CLI/test scenarios.
    private static func queryEnvironment() -> EditorResolution? {
        let env = ProcessInfo.processInfo.environment
        let path = env["PATH"]?.trimmingCharacters(in: .whitespaces)
        if let visual = env["VISUAL"]?.trimmingCharacters(in: .whitespaces), !visual.isEmpty {
            print("EditorService: resolved editor='\(visual)' via ProcessInfo VISUAL")
            return EditorResolution(editor: visual, path: (path?.isEmpty == false) ? path : nil)
        }
        if let editor = env["EDITOR"]?.trimmingCharacters(in: .whitespaces), !editor.isEmpty {
            print("EditorService: resolved editor='\(editor)' via ProcessInfo EDITOR")
            return EditorResolution(editor: editor, path: (path?.isEmpty == false) ? path : nil)
        }
        print("EditorService: no editor resolvable — falling back to built-in NSTextView")
        return nil
    }
}

// MARK: - TCA Dependency

extension EditorService: DependencyKey {
    static var liveValue: EditorService { .live }

    static var testValue: EditorService {
        EditorService(
            resolveEditor: { nil },
            buildCommand: { _ in nil },
            warmUp: {}
        )
    }
}

extension DependencyValues {
    var editorService: EditorService {
        get { self[EditorService.self] }
        set { self[EditorService.self] = newValue }
    }
}
