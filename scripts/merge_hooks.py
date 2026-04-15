#!/usr/bin/env python3
"""Deep-merge Claude Code hooks into a settings.json file.

Usage: merge_hooks.py <settings-path> <hooks-json>

Preserves unrelated user hooks. Dedupes by command string so repeated runs
don't accumulate duplicates. Updates matcher when it has changed.
"""
import json
import sys


def merge_hooks(settings: dict, new_hooks: dict) -> dict:
    settings.setdefault("hooks", {})
    for event, new_groups in new_hooks.items():
        existing_groups = settings["hooks"].setdefault(event, [])
        for new_group in new_groups:
            new_matcher = new_group.get("matcher")
            new_inner = new_group["hooks"]
            new_commands = {
                h.get("command") for h in new_inner if h.get("type") == "command"
            }

            for grp in existing_groups:
                grp["hooks"] = [
                    h
                    for h in grp.get("hooks", [])
                    if not (
                        h.get("type") == "command"
                        and h.get("command") in new_commands
                    )
                ]
            existing_groups[:] = [g for g in existing_groups if g.get("hooks")]

            target = next(
                (g for g in existing_groups if g.get("matcher") == new_matcher),
                None,
            )
            if target:
                target["hooks"].extend(new_inner)
            else:
                existing_groups.append(new_group)
    return settings


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: merge_hooks.py <settings-path> <hooks-json>", file=sys.stderr)
        return 2
    settings_path, hooks_json = sys.argv[1], sys.argv[2]
    with open(settings_path) as f:
        settings = json.load(f)
    new_hooks = json.loads(hooks_json)["hooks"]
    merge_hooks(settings, new_hooks)
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
