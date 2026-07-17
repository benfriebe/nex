#!/usr/bin/env python3
"""Deep-merge Claude Code / Codex CLI hooks into a hooks config file
(Claude's settings.json and Codex's hooks.json share the same
three-level "hooks" shape).

Usage: merge_hooks.py <settings-path> <hooks-json>

Preserves unrelated user hooks. Dedupes nex-managed hooks by the
command's flag-less base (any existing command *containing* an
incoming command's prefix before its first ` --` counts), so both
`/Applications/Nex.app/Contents/Helpers/nex event stop` AND a
hand-wired bare `nex event stop` are replaced by the incoming
`nex event stop --agent codex` rather than left to double-fire.
Updates matcher when it has changed.

Deliberate trade-off: the substring sweep also removes a *composite*
user command that embeds a nex base (e.g. `notify.sh && nex event
stop`) from the target event, treating it as nex-managed. Keeping such
a command would double-fire the nex event, which is the worse failure
mode.
"""
import json
import sys


def base_command(command: str) -> str:
    """The command prefix before any ` --` flag — the identity used for
    nex-managed dedupe. `nex event stop --agent codex`, a bare
    `nex event stop`, and an absolute-path variant all share the base
    `nex event stop`."""
    return command.split(" --")[0].strip()


def merge_hooks(settings: dict, new_hooks: dict) -> dict:
    settings.setdefault("hooks", {})
    for event, new_groups in new_hooks.items():
        existing_groups = settings["hooks"].setdefault(event, [])
        for new_group in new_groups:
            new_matcher = new_group.get("matcher")
            new_inner = new_group["hooks"]
            new_bases = {
                base_command(h["command"])
                for h in new_inner
                if h.get("type") == "command" and h.get("command")
            }

            def is_nex_managed(command):
                return command is not None and any(
                    base in command for base in new_bases
                )

            for grp in existing_groups:
                grp["hooks"] = [
                    h
                    for h in grp.get("hooks", [])
                    if not (
                        h.get("type") == "command"
                        and is_nex_managed(h.get("command"))
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
