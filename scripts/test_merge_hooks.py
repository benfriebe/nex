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
            "matcher": "startup|resume|clear|compact",
            "hooks": [{"type": "command", "command": "nex event session-start"}],
        }
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

    def test_updates_stale_matcher(self):
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
        self.assertEqual(matchers, ["startup|resume|clear|compact"])
        self.assertNotIn("startup", [m for m in matchers if m != "startup|resume|clear|compact"])

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
