import Foundation
@testable import Nex
import Testing

struct EditorServiceTests {
    @Test func singleQuoteEscapePassesPlainStringsThrough() {
        #expect(EditorService.singleQuoteEscape("") == "")
        #expect(EditorService.singleQuoteEscape("/tmp/plan.md") == "/tmp/plan.md")
        #expect(EditorService.singleQuoteEscape("with spaces.md") == "with spaces.md")
    }

    @Test func singleQuoteEscapeHandlesEmbeddedQuotes() {
        // A single apostrophe becomes '\'' — close quote, escaped quote, reopen.
        #expect(EditorService.singleQuoteEscape("it's") == #"it'\''s"#)
        #expect(EditorService.singleQuoteEscape("o'neil's.md") == #"o'\''neil'\''s.md"#)
    }

    @Test func formatCommandWithoutPathReturnsBareCommand() {
        // When we don't have a login PATH (e.g., resolution fell back to
        // ProcessInfo), emit the editor + file directly. Ghostty wraps this
        // in /bin/sh -c at launch; the shell uses its default PATH.
        let cmd = EditorService.formatCommand(
            editor: "nvim",
            filePath: "/tmp/plan.md",
            loginPath: nil
        )
        #expect(cmd == "nvim '/tmp/plan.md'")
    }

    @Test func formatCommandWrapsInEnvWhenPathKnown() {
        // Using /usr/bin/env (not inline PATH=…) is required because ghostty
        // wraps commands as `bash -c "exec -l <cmd>"`, and bash's exec builtin
        // won't parse `PATH=val cmd` as a simple-command assignment — it
        // treats the assignment-looking word as a program name and fails.
        let cmd = EditorService.formatCommand(
            editor: "nvim",
            filePath: "/tmp/plan.md",
            loginPath: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        )
        #expect(cmd == "/usr/bin/env PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' nvim '/tmp/plan.md'")
    }

    @Test func formatCommandEscapesFilePathWithSpaces() {
        let cmd = EditorService.formatCommand(
            editor: "vim",
            filePath: "/tmp/my plan.md",
            loginPath: "/usr/bin:/bin"
        )
        #expect(cmd == "/usr/bin/env PATH='/usr/bin:/bin' vim '/tmp/my plan.md'")
    }

    @Test func formatCommandEscapesFilePathWithSingleQuote() {
        let cmd = EditorService.formatCommand(
            editor: "nvim",
            filePath: "/tmp/dan's plan.md",
            loginPath: nil
        )
        // Single quote in the file path is closed-escaped-reopened.
        #expect(cmd == #"nvim '/tmp/dan'\''s plan.md'"#)
    }

    @Test func formatCommandEscapesLoginPathWithSingleQuote() {
        // Directory names with apostrophes are rare but legal on macOS.
        let cmd = EditorService.formatCommand(
            editor: "nvim",
            filePath: "/tmp/plan.md",
            loginPath: "/Users/dan's bin:/usr/bin"
        )
        #expect(cmd == #"/usr/bin/env PATH='/Users/dan'\''s bin:/usr/bin' nvim '/tmp/plan.md'"#)
    }

    @Test func formatCommandPreservesEditorFlags() {
        // Common case: $EDITOR="code -w" or "nvim -p"
        let cmd = EditorService.formatCommand(
            editor: "code -w",
            filePath: "/tmp/plan.md",
            loginPath: "/usr/bin:/bin"
        )
        #expect(cmd == "/usr/bin/env PATH='/usr/bin:/bin' code -w '/tmp/plan.md'")
    }

    @Test func formatCommandTreatsEmptyPathAsNoPath() {
        // An empty PATH is useless and would produce `PATH='' editor 'file'`
        // which breaks the launch; treat it like nil.
        let cmd = EditorService.formatCommand(
            editor: "vim",
            filePath: "/tmp/plan.md",
            loginPath: ""
        )
        #expect(cmd == "vim '/tmp/plan.md'")
    }

    @Test func resolveUserShellReturnsAbsolutePath() {
        // getpwuid is authoritative on macOS; we don't mock it, but we can
        // assert the result is a plausible absolute path.
        let shell = EditorService.resolveUserShell()
        #expect(shell.hasPrefix("/"))
        #expect(!shell.isEmpty)
    }

    @Test func tcaTestValueReturnsNilEditor() {
        // The TCA test value is deliberately nil so reducers under test
        // exercise the "no editor resolvable" fallback branch.
        #expect(EditorService.testValue.resolveEditor() == nil)
        #expect(EditorService.testValue.buildCommand("/tmp/plan.md") == nil)
    }

    @Test func parseShellOutputExtractsValuesFromCleanOutput() {
        let output = """

        \(EditorService.shellOutputBeginMarker)
        nvim
        vim
        /opt/homebrew/bin:/usr/bin:/bin
        \(EditorService.shellOutputEndMarker)

        """
        let parsed = EditorService.parseShellOutput(output)
        #expect(parsed.visual == "nvim")
        #expect(parsed.editor == "vim")
        #expect(parsed.path == "/opt/homebrew/bin:/usr/bin:/bin")
    }

    @Test func parseShellOutputSurvivesShellInitBanner() {
        // A .zshrc that prints a welcome banner, gitstatus debug, direnv
        // output, etc. must not shift our parse — the sentinel marker
        // anchors the positional read.
        let output = """
        Last login: Mon Apr  1 09:12:03 on ttys003
        [direnv] loading ~/.envrc
        gitstatusd: starting
        Welcome back!

        \(EditorService.shellOutputBeginMarker)

        nvim
        /opt/homebrew/bin:/usr/bin
        \(EditorService.shellOutputEndMarker)
        """
        let parsed = EditorService.parseShellOutput(output)
        // VISUAL was empty (printf emitted a blank line), EDITOR is nvim.
        #expect(parsed.visual == "")
        #expect(parsed.editor == "nvim")
        #expect(parsed.path == "/opt/homebrew/bin:/usr/bin")
    }

    @Test func parseShellOutputReturnsEmptyWhenMarkerMissing() {
        // Shell crashed or was watchdog-killed before printf ran — no
        // marker means no values, so caller falls back cleanly.
        let parsed = EditorService.parseShellOutput("oh-my-zsh: command not found: foo\n")
        #expect(parsed.visual == "")
        #expect(parsed.editor == "")
        #expect(parsed.path == "")
    }

    @Test func parseShellOutputTreatsEndMarkerAsEmptyField() {
        // If printf was interrupted partway through (e.g. $PATH unset and
        // printf only emitted two values), we should see the end marker
        // where a value would be — treat that as empty, not as the literal
        // marker string.
        let output = """
        \(EditorService.shellOutputBeginMarker)
        nvim
        \(EditorService.shellOutputEndMarker)
        """
        let parsed = EditorService.parseShellOutput(output)
        #expect(parsed.visual == "nvim")
        #expect(parsed.editor == "")
        #expect(parsed.path == "")
    }
}
