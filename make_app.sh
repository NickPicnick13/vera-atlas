#!/bin/bash
# Собирает запускаемый .app из swift build: .build/app/VeraAtlas.app
# (WKWebView нужен настоящий bundle, поэтому бинарник из .build/debug оборачиваем в .app)
set -euo pipefail
cd "$(dirname "$0")"

BIN=".build/debug/VeraDesktopWidget"
APP=".build/app/VeraAtlas.app"

# Bundle only a successful compile of the current source; never remove the running app tree.
swift build
[[ -x "$BIN" ]] || { echo "не найден собранный бинарник $BIN" >&2; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Staged per-file replacements prevent partial reads; publish the HTML and executable last.
python3 - "$BIN" "$APP" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
cwd = pathlib.Path.cwd()
base = pathlib.Path(sys.argv[2]).resolve()
if base != cwd/'.build/app/VeraAtlas.app':
    raise SystemExit('Unexpected bundle location')
# Public build must package a reproducible SYNTHETIC graph, never a user's
# Obsidian or DSH memory snapshot.
graph = (cwd/'examples/demo-graph.json').read_bytes()
model = json.loads(graph)
if not model.get('nodes') or set(model) != {'nodes', 'edges'}:
    raise SystemExit('Missing sanitized base graph; keep the running bundle unchanged')
files = [('sphere.js', 'Resources/sphere.js'), ('atlas.js', 'Resources/atlas.js'),
         (None, 'Resources/atlas-base.json'), ('Info.plist', 'Info.plist'),
         ('proto.html', 'Resources/proto.html'), (sys.argv[1], 'MacOS/VeraAtlas')]
for src, relative in files:
    dst = base/'Contents'/relative
    if not dst.parent.resolve().is_relative_to(base):
        raise SystemExit('Resource directory leaves the app bundle')
    with tempfile.NamedTemporaryFile(dir=dst.parent, prefix='.publish-', delete=False) as tmp:
        staged = pathlib.Path(tmp.name)
    try:
        if src is None:
            staged.write_bytes(graph)
        else:
            shutil.copyfile(src, staged)
        staged.chmod(0o755 if relative.startswith('MacOS/') else 0o644)
        os.replace(staged, dst)
    finally:
        staged.unlink(missing_ok=True)
PY
printf 'APPL????' > "$APP/Contents/PkgInfo"
/usr/bin/codesign --force --sign - --identifier org.vera-atlas.community "$APP"
/usr/bin/codesign --verify --strict "$APP"
echo "assembled: $APP"
