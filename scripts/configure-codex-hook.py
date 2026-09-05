#!/usr/bin/env python3
"""Update only this hook's registrations and preserve other config values."""

import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import re
import shlex
import tempfile

try:
    import tomllib
except ImportError:
    raise SystemExit("Installation needs Python 3.11 or newer. The hook itself only runs Swift.")


EVENTS = {"UserPromptSubmit": "turn_start", "Stop": "turn_end"}
TABLE = re.compile(r"(?m)^[ \t]*(\[.+\])[ \t]*(?:#.*)?$")


def owned_command(command):
    try:
        words = shlex.split(command)
    except ValueError:
        return False
    if not words:
        return False
    return Path(words[0]).name in {"system-health-context", "system-health-codex-hook.zsh"}


def expected_command(binary, mode):
    return f"{shlex.quote(str(binary))} --codex-hook {mode}"


def updated_hooks(original, binary):
    hooks = copy.deepcopy(original)
    for event, mode in EVENTS.items():
        groups = hooks.get(event, [])
        matches = [(group, index) for group in groups
                   for index, hook in enumerate(group.get("hooks", []))
                   if owned_command(hook.get("command", ""))]
        if len(matches) > 1:
            raise ValueError(f"Duplicate System Health Hooks for {event}; remove duplicates before installing")
        replacement = {
            "type": "command",
            "command": expected_command(binary, mode),
            "timeout": 5,
            "statusMessage": "Collecting system health context" if mode == "turn_start" else "Checking end-of-turn system health",
        }
        # Saved trust and enabled state use group/handler indexes. Keep them stable.
        if matches:
            group, index = matches[0]
            group["hooks"][index] = replacement
        else:
            groups.append({"hooks": [replacement]})
        hooks[event] = groups
    return hooks


def toml_value(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(v) for v in value) + "]"
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{toml_value(k)} = {toml_value(v)}" for k, v in value.items()) + " }"
    raise ValueError("Unsupported config value")


def render_config(source, binary):
    original = tomllib.loads(source)
    desired = copy.deepcopy(original)
    desired["hooks"] = updated_hooks(original.get("hooks", {}), binary)
    headers = list(TABLE.finditer(source))
    ranges = []
    for index, header in enumerate(headers):
        try:
            table = tomllib.loads(header[1] + "\n")
        except tomllib.TOMLDecodeError:
            continue
        if "hooks" in table:
            end = headers[index + 1].start() if index + 1 < len(headers) else len(source)
            ranges.append((header.start(), end))
    if "hooks" in original and not ranges:
        raise ValueError("Cannot locate hooks tables; configuration left unchanged")
    result = source
    for start, end in reversed(ranges):
        result = result[:start] + result[end:]
    block = "\n[hooks]\n" + "\n".join(
        f"{toml_value(key)} = {toml_value(value)}" for key, value in desired["hooks"].items()
    ) + "\n"
    result = result.rstrip() + "\n" + block
    # Header-like text inside multiline strings must never corrupt unrelated config.
    if tomllib.loads(result) != desired:
        raise ValueError("Config preservation check failed; configuration left unchanged")
    return result


def verify(source, binary):
    hooks = tomllib.loads(source).get("hooks", {})
    for event, mode in EVENTS.items():
        matches = [(group, hook) for group in hooks.get(event, []) for hook in group.get("hooks", [])
                   if owned_command(hook.get("command", ""))]
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one System Health Hook for {event}")
        group, hook = matches[0]
        # Neither event uses a matcher; existing group metadata can be preserved.
        if (hook.get("type") != "command"
                or hook.get("command") != expected_command(binary, mode)
                or hook.get("timeout") != 5):
            raise ValueError(f"{event} does not use the expected unconditional hook")


def atomic_write(path, text):
    fd, temporary = tempfile.mkstemp(prefix=".system-health-config-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    config = args.config.expanduser().resolve()
    binary = args.binary.expanduser().resolve()
    source = config.read_text() if config.exists() else ""
    if args.check:
        verify(source, binary)
    else:
        result = render_config(source, binary)
        verify(result, binary)
        config.parent.mkdir(parents=True, exist_ok=True)
        if result != source:
            if (config.read_text() if config.exists() else "") != source:
                raise ValueError("Config changed during installation; rerun the installer")
            if config.exists():
                fd, backup = tempfile.mkstemp(prefix=config.name + ".before-system-health-", dir=config.parent)
                with os.fdopen(fd, "w") as stream:
                    stream.write(source)
                print(f"Config backup: {backup}")
            atomic_write(config, result)
        verify(config.read_text(), binary)
    print(f"Verified UserPromptSubmit and Stop registrations for {binary}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError, OSError) as error:
        raise SystemExit(f"Hook configuration failed: {error}")
