#!/usr/bin/env python3
"""Tests for merge_hooks.merge_hooks.

Run: python3 scripts/test_merge_hooks.py
"""
import copy
import unittest

from merge_hooks import merge_hooks


NEX_HOOKS = {
    "Stop": [{"hooks": [{"type": "command", "command": "nex event stop"}]}],
    "Notification": [
        {"hooks": [{"type": "command", "command": "nex event notification"}]}
    ],
    "SessionStart": [
        {
            "hooks": [{"type": "command", "command": "nex event session-start"}],
        }
    ],
    "SessionEnd": [
        {"hooks": [{"type": "command", "command": "nex event session-end"}]}
    ],
    "UserPromptSubmit": [
        {"hooks": [{"type": "command", "command": "nex event start"}]}
    ],
}


class MergeHooksTests(unittest.TestCase):
    def test_empty_settings_gets_all_nex_hooks(self):
        settings = {}
        merge_hooks(settings, copy.deepcopy(NEX_HOOKS))
        self.assertEqual(settings["hooks"]["Stop"], NEX_HOOKS["Stop"])
        self.assertEqual(settings["hooks"]["SessionStart"], NEX_HOOKS["SessionStart"])
        self.assertEqual(settings["hooks"]["SessionEnd"], NEX_HOOKS["SessionEnd"])

    def test_idempotent_no_duplicates(self):
        settings = {}
        merge_hooks(settings, copy.deepcopy(NEX_HOOKS))
        merge_hooks(settings, copy.deepcopy(NEX_HOOKS))
        stop_commands = [
            h["command"]
            for g in settings["hooks"]["Stop"]
            for h in g["hooks"]
        ]
        self.assertEqual(stop_commands, ["nex event stop"])

    def test_preserves_unrelated_event(self):
        settings = {
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Bash",
                        "hooks": [{"type": "command", "command": "audit-bash"}],
                    }
                ]
            }
        }
        merge_hooks(settings, copy.deepcopy(NEX_HOOKS))
        self.assertEqual(
            settings["hooks"]["PreToolUse"][0]["hooks"][0]["command"], "audit-bash"
        )

    def test_preserves_user_command_on_same_event(self):
        settings = {
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "my-custom-stop"}]}
                ]
            }
        }
        merge_hooks(settings, copy.deepcopy(NEX_HOOKS))
        commands = [
            h["command"]
            for g in settings["hooks"]["Stop"]
            for h in g["hooks"]
        ]
        self.assertIn("my-custom-stop", commands)
        self.assertIn("nex event stop", commands)

    def test_migrates_pre_v019_startup_matcher(self):
        # Pre-v0.19 installs wrote `"matcher": "startup"`, which never
        # fires for resumed sessions (issue #181). Re-running the
        # installer must replace that group with the matcher-less one.
        settings = {
            "hooks": {
                "SessionStart": [
                    {
                        "matcher": "startup",
                        "hooks": [
                            {"type": "command", "command": "nex event session-start"}
                        ],
                    }
                ]
            }
        }
        merge_hooks(settings, copy.deepcopy(NEX_HOOKS))
        matchers = [g.get("matcher") for g in settings["hooks"]["SessionStart"]]
        self.assertEqual(matchers, [None])

    def test_migrates_v019_widened_matcher(self):
        # v0.19 through v0.31 wrote an explicit source list; the
        # matcher-less group supersedes it (fires for future sources too).
        settings = {
            "hooks": {
                "SessionStart": [
                    {
                        "matcher": "startup|resume|clear|compact",
                        "hooks": [
                            {"type": "command", "command": "nex event session-start"}
                        ],
                    }
                ]
            }
        }
        merge_hooks(settings, copy.deepcopy(NEX_HOOKS))
        matchers = [g.get("matcher") for g in settings["hooks"]["SessionStart"]]
        self.assertEqual(matchers, [None])

    def test_dedupe_across_groups(self):
        settings = {
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "nex event stop"}]},
                    {"hooks": [{"type": "command", "command": "keep-me"}]},
                ]
            }
        }
        merge_hooks(settings, copy.deepcopy(NEX_HOOKS))
        commands = [
            h["command"]
            for g in settings["hooks"]["Stop"]
            for h in g["hooks"]
        ]
        self.assertEqual(commands.count("nex event stop"), 1)
        self.assertIn("keep-me", commands)

    def test_dedupes_absolute_path_nex_commands(self):
        # A hand-edited absolute-path variant is still the nex hook;
        # leaving it alongside the bare command would double-fire, and
        # a stale matcher on its group would survive "repair" runs.
        settings = {
            "hooks": {
                "SessionStart": [
                    {
                        "matcher": "startup",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "/Applications/Nex.app/Contents/Helpers/nex event session-start",
                            }
                        ],
                    }
                ],
                "Stop": [
                    {
                        "hooks": [
                            {"type": "command", "command": "/usr/local/bin/nex event stop"}
                        ]
                    }
                ],
            }
        }
        merge_hooks(settings, copy.deepcopy(NEX_HOOKS))
        ss_commands = [
            h["command"]
            for g in settings["hooks"]["SessionStart"]
            for h in g["hooks"]
        ]
        self.assertEqual(ss_commands, ["nex event session-start"])
        self.assertEqual(
            [g.get("matcher") for g in settings["hooks"]["SessionStart"]], [None]
        )
        stop_commands = [
            h["command"] for g in settings["hooks"]["Stop"] for h in g["hooks"]
        ]
        self.assertEqual(stop_commands, ["nex event stop"])

    def test_mixed_group_keeps_user_command(self):
        # Stripping the nex command from a shared group must not drop
        # the user's own hook that lives beside it.
        settings = {
            "hooks": {
                "SessionStart": [
                    {
                        "matcher": "startup",
                        "hooks": [
                            {"type": "command", "command": "nex event session-start"},
                            {"type": "command", "command": "my-own-session-logger"},
                        ],
                    }
                ]
            }
        }
        merge_hooks(settings, copy.deepcopy(NEX_HOOKS))
        all_hooks = [
            (g.get("matcher"), h["command"])
            for g in settings["hooks"]["SessionStart"]
            for h in g["hooks"]
        ]
        self.assertIn(("startup", "my-own-session-logger"), all_hooks)
        self.assertIn((None, "nex event session-start"), all_hooks)

    def test_codex_flagged_command_replaces_hand_wired_bare_command(self):
        # Issue #101 migration wart: early adopters hand-wired bare
        # `nex event ...` commands into ~/.codex/hooks.json before the
        # installer grew codex support. The incoming flagged variant
        # (`--agent codex`) must replace them — a survivor would
        # double-fire AND flip the pane's agent kind back to claude on
        # every event (its session_id dual-fire parses as claude).
        codex_hooks = {
            "Stop": [
                {
                    "hooks": [
                        {"type": "command", "command": "nex event stop --agent codex"}
                    ]
                }
            ]
        }
        settings = {
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "nex event stop"}]}
                ]
            }
        }
        merge_hooks(settings, codex_hooks)
        commands = [
            h["command"] for g in settings["hooks"]["Stop"] for h in g["hooks"]
        ]
        self.assertEqual(commands, ["nex event stop --agent codex"])

    def test_codex_flagged_command_idempotent(self):
        codex_hooks = {
            "Stop": [
                {
                    "hooks": [
                        {"type": "command", "command": "nex event stop --agent codex"}
                    ]
                }
            ]
        }
        settings = {}
        merge_hooks(settings, copy.deepcopy(codex_hooks))
        merge_hooks(settings, copy.deepcopy(codex_hooks))
        commands = [
            h["command"] for g in settings["hooks"]["Stop"] for h in g["hooks"]
        ]
        self.assertEqual(commands, ["nex event stop --agent codex"])

    def test_flagged_dedupe_keeps_user_command(self):
        # The flag-less base ("nex event stop") must only sweep up
        # nex-managed variants, not a user's own hook on the same event.
        codex_hooks = {
            "Stop": [
                {
                    "hooks": [
                        {"type": "command", "command": "nex event stop --agent codex"}
                    ]
                }
            ]
        }
        settings = {
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "my-custom-stop"}]},
                    {
                        "hooks": [
                            {
                                "type": "command",
                                "command": "/usr/local/bin/nex event stop --agent codex",
                            }
                        ]
                    },
                ]
            }
        }
        merge_hooks(settings, codex_hooks)
        commands = [
            h["command"] for g in settings["hooks"]["Stop"] for h in g["hooks"]
        ]
        self.assertEqual(
            commands, ["my-custom-stop", "nex event stop --agent codex"]
        )

    def test_preserves_non_command_hook_types(self):
        settings = {
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "other", "script": "foo.sh"}]}
                ]
            }
        }
        merge_hooks(settings, copy.deepcopy(NEX_HOOKS))
        all_hooks = [h for g in settings["hooks"]["Stop"] for h in g["hooks"]]
        self.assertTrue(any(h.get("type") == "other" for h in all_hooks))
        self.assertTrue(any(h.get("command") == "nex event stop" for h in all_hooks))


if __name__ == "__main__":
    unittest.main()
