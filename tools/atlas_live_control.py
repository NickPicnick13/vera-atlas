#!/usr/bin/env python3
"""Live Atlas menu control over a local, acknowledged macOS notification.

This changes the very same settings as the menu. No fabricated graph events,
network, model call, simulator, screen recording, or new background process.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

APP_IDS = {
    "private": "local.vera.desktop-widget",
    "community": "org.vera-atlas.community",
}
PREFS = {
    "comets": ("veraAtlasShowComets", "off"),
    "idle-lines": ("veraAtlasShowIdleLines", "off"),
    "work-lines": ("veraAtlasContinuousWorkLines", "off"),
    "adaptive-shape": ("veraAtlasAdaptiveShapeEnabled", "on"),
    "dual": ("veraAtlasDualDisplayEnabled", "off"),
    "backdrop": ("veraAtlasBackdropEnabled", "off"),
    "speed": ("veraAtlasMotionSpeed", "1.0"),
    "screen": ("veraAtlasBackdropScreenID", ""),
}
COMMANDS = tuple(PREFS)


def preference(bundle: str, key: str, fallback: str) -> str:
    try:
        result = subprocess.run(
            ["defaults", "read", bundle, key],
            capture_output=True, text=True, timeout=4, check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return fallback
    return result.stdout.strip() if result.returncode == 0 else fallback


def running(app: str) -> bool:
    if app == "private":
        cmd = ["launchctl", "list"]
        needle = "com.nick.vera-widget"
    else:
        cmd = ["pgrep", "-fl", "/VeraAtlas.app/Contents/MacOS/VeraAtlas"]
        needle = "VeraAtlas.app"
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return out.returncode == 0 and needle in out.stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def helper(root: Path) -> Path:
    source = root / "atlas_live_bridge.swift"
    target = root / ".build" / "atlas_live_bridge"
    if not source.is_file():
        raise RuntimeError("Swift control source is missing")
    if not target.is_file() or target.stat().st_mtime_ns < source.stat().st_mtime_ns:
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = target.with_name("atlas_live_bridge.building")
        completed = subprocess.run(
            ["swiftc", str(source), "-o", str(temp)],
            capture_output=True, text=True, timeout=90, check=False,
        )
        if completed.returncode:
            temp.unlink(missing_ok=True)
            raise RuntimeError("Swift bridge failed to compile: " + completed.stderr[-1200:])
        temp.replace(target)
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", choices=APP_IDS, default="community",
                        help="App to control. Public build is the safe default.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Validate but do not send a control signal.")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status", help="Read current choices without making changes.")
    for name in COMMANDS:
        cmd = sub.add_parser(name)
        if name == "speed":
            cmd.add_argument("value", type=float)
        elif name == "screen":
            cmd.add_argument("value", help="main, other, or part of a display name")
        else:
            cmd.add_argument("value", choices=("on", "off"))
    args = parser.parse_args()
    bundle = APP_IDS[args.app]
    if args.command == "status":
        print(json.dumps({
            "ok": True, "app": args.app, "running": running(args.app),
            "settings": {
                name: preference(bundle, key, fallback)
                for name, (key, fallback) in PREFS.items()
            },
        }, ensure_ascii=False))
        return 0
    value = str(args.value)
    if args.command == "speed":
        if not 0 <= args.value <= 3:
            parser.error("speed must be between 0 and 3")
        value = str(round(args.value, 1))
    if args.dry_run:
        print(json.dumps({"ok": True, "dry_run": True, "app": args.app,
                          "option": args.command, "value": value}))
        return 0
    if not running(args.app):
        raise RuntimeError("Target Atlas is not running; command not applied")
    result = subprocess.run(
        [str(helper(Path(__file__).resolve().parent)),
         bundle, args.command, value],
        capture_output=True, text=True, timeout=15, check=False,
    )
    if result.returncode:
        raise RuntimeError("Atlas did not acknowledge control: " +
                           (result.stderr or result.stdout).strip()[-800:])
    key, fallback = PREFS[args.command]
    actual = preference(bundle, key, fallback)
    print(json.dumps({
        "ok": True, "acknowledged": True, "app": args.app,
        "option": args.command, "requested": value, "stored": actual,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False),
              file=sys.stderr)
        sys.exit(2)
