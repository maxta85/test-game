#!/usr/bin/env bash
# Build the Windows release artefact from a Godot checkout.
#
# Runs headless on Linux, which is the point: the shipping artefact is
# reproducible from CI without a Windows box.
#
#   ./windows/package-windows.sh              export + checksums
#   ./windows/package-windows.sh --tag=v0.1.0  also write windows/manifest.json
#
# Env:
#   GODOT       path to the godot 4.3 binary (default /home/coder/tools/godot)
#   VERSION     version string (default 0.1.0)
#   SKIP_TESTS  set to 1 to skip the test.sh gate
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GODOT="${GODOT:-/home/coder/tools/godot}"
VERSION="${VERSION:-0.1.0}"
PRESET="Windows Desktop"
ARTIFACT="CairnsAfterDark.exe"
OUT="build/$ARTIFACT"
TEMPLATE_DIR="$HOME/.local/share/godot/export_templates/4.3.stable"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# --- 0. sanity ------------------------------------------------------------
[ -x "$GODOT" ] || die "godot not found or not executable: $GODOT"
"$GODOT" --version | grep -q '4\.3\.' || die "need Godot 4.3, got: $("$GODOT" --version)"
say "godot: $("$GODOT" --version)"

# Godot 4.3 has no --install-export-templates flag (it silently boots the
# project instead), so the templates must be unpacked by hand into the
# per-version directory. windows/README.md documents the one-time step.
[ -f "$TEMPLATE_DIR/windows_release_x86_64.exe" ] || die \
  "export templates missing. Unpack Godot_v4.3-stable_export_templates.tpz into $TEMPLATE_DIR (see windows/README.md)"
say "export templates: present"

# --- 1. gate on a green test run ------------------------------------------
# A build that does not pass its own tests is not a release.
if [ "${SKIP_TESTS:-0}" != "1" ]; then
  say "running ./test.sh"
  ./test.sh
fi

# --- 2. export ------------------------------------------------------------
# The preset embeds the .pck in the .exe (binary_format/embed_pck=true), so
# the artefact is a single file. build/ is in the preset's exclude_filter,
# which is what stops an export from packing the previous export into itself.
mkdir -p build
if [ "${SKIP_EXPORT:-0}" = "1" ] && [ -f "$OUT" ]; then
  say "SKIP_EXPORT=1 and $OUT exists - reusing the existing artefact"
else
  say "exporting $PRESET -> $OUT (a few minutes, the first run imports assets)"
  "$GODOT" --headless --path "$ROOT" --export-release "$PRESET" "$OUT"
fi

[ -f "$OUT" ] || die "export produced no $OUT"
# A stale sidecar .pck would mean embed_pck silently stopped working.
if [ -f "build/$ARTIFACT.pck" ]; then
  die "unexpected build/$ARTIFACT.pck - the .pck is supposed to be embedded"
fi
say "artefact: $OUT ($(du -h "$OUT" | cut -f1))"

# --- 3. checksum ----------------------------------------------------------
# The launcher refuses to install a payload whose SHA-256 does not match, so
# this file is the trust anchor for the whole download path.
say "writing build/SHA256SUMS"
( cd build && sha256sum "$ARTIFACT" > SHA256SUMS )
cat "build/SHA256SUMS"

# --- 4. manifest (optional) ----------------------------------------------
# The launcher reads the pinned tag + digest from windows/manifest.json. It
# deliberately does NOT auto-follow "latest": a launcher that silently installs
# whatever is newest is how players get an untested build. New releases mean a
# deliberate manifest bump, which is also the upgrade trigger.
case "${1:-}" in
--tag|--tag=*) WANT_MANIFEST=1 ;;
*)              WANT_MANIFEST=0 ;;
esac

if [ "$WANT_MANIFEST" = 1 ]; then
  TAG="v$VERSION"
  SHA="$(cut -d' ' -f1 build/SHA256SUMS)"
  SIZE="$(stat -c%s "$OUT")"
  say "writing windows/manifest.json ($TAG, $SIZE bytes)"
  # Emitted by python rather than a heredoc: the Windows paths contain
  # backslashes, and a bash heredoc silently eats one of them, which produces
  # a manifest that is not valid JSON at exactly the moment the launcher
  # starts trusting it. json.dumps cannot get that wrong.
  python3 - "$VERSION" "$TAG" "$ARTIFACT" "$SHA" "$SIZE" > windows/manifest.json <<'PY'
import json, sys
version, tag, asset, sha, size = sys.argv[1:6]
json.dump({
    "game": "Cairns After Dark",
    "version": version,
    "tag": tag,
    "asset": asset,
    "sha256": sha,
    "size": int(size),
    "repo": "maxta85/test-game",
    "releases_url": "https://github.com/maxta85/test-game/releases",
    "saves_path": r"%APPDATA%\CairnsAfterDark",
}, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
  python3 -c "import json,sys; json.load(open('windows/manifest.json'))" \
    || die "generated manifest is not valid JSON"
fi

# --- 5. installer bundle --------------------------------------------------
# The small bootstrap the user actually downloads. It deliberately does NOT
# contain the 182 MB exe: the launcher fetches that from the release and
# verifies it, so the first download is a few KB and the payload arrives
# with a checksum that is checked before it is ever run.
BUNDLE="build/CairnsAfterDark-Installer-$VERSION.zip"
STAGE="build/bundle-$VERSION"
rm -rf "$STAGE"; mkdir -p "$STAGE/launcher"
cp windows/CairnsAfterDark.bat "$STAGE/"
cp windows/install.ps1        "$STAGE/launcher/"
[ -f windows/manifest.json ] || die "run with --tag=v$VERSION so windows/manifest.json exists"
cp windows/manifest.json      "$STAGE/launcher/"
cp build/SHA256SUMS           "$STAGE/"

cat > "$STAGE/README.txt" <<TXT
Cairns After Dark - $VERSION
===========================

INSTALL
  1. Extract this zip anywhere you like, e.g. C:\\Games\\CairnsAfterDark
  2. Double-click CairnsAfterDark.bat
  3. It downloads the game, checks its SHA-256, and puts Start-menu and
     desktop shortcuts in place.

You do NOT need Godot, Git, Python or any developer tools. The first run
needs internet access; after that the game runs offline.

SAVES
  %APPDATA%\\CairnsAfterDark

  Saves are kept outside the install folder on purpose, so updating or
  reinstalling to a different folder cannot lose your progress.

UNINSTALL
  Start menu -> Uninstall Cairns After Dark, or run:
      CairnsAfterDark.bat Uninstall
  This removes the game and the shortcuts and leaves your saves alone.

Other actions:
      CairnsAfterDark.bat Install     install/repair only
      CairnsAfterDark.bat Update      offer a newer release
TXT

# python's zipfile rather than the zip(1) binary: it is stdlib, so the build
# has one less tool to install, and it writes the same archive.
python3 - "$STAGE" "$BUNDLE" <<'PY' || die "could not build the installer bundle"
import os, sys, zipfile
stage, bundle = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(bundle, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _dirs, files in os.walk(stage):
        for name in sorted(files):
            full = os.path.join(root, name)
            z.write(full, os.path.relpath(full, stage))
PY
say "installer bundle: $BUNDLE ($(du -h "$BUNDLE" | cut -f1))"
( cd build && sha256sum "$(basename "$BUNDLE")" >> SHA256SUMS )

# --- 6. prove the payload is real, not a Git LFS pointer ------------------
# The 7 car models are LFS-tracked, and GitHub's zip download does not run the
# smudge filter - a zip of the repo would ship 133-byte text stubs and no
# cars. The release is built from this worktree and from the exported pack,
# so this asserts the payload is a real PE with a real embedded PCK.
python3 - "$OUT" <<'PY' || die "artefact failed its structural check"
import os, struct, sys
p = sys.argv[1]
size = os.path.getsize(p)
with open(p, 'rb') as f:
    assert f.read(2) == b'MZ', 'not a PE image'
    f.seek(0x3C); pe = struct.unpack('<I', f.read(4))[0]
    f.seek(pe)
    assert f.read(4) == b'PE\0\0', 'no PE signature'
    machine = struct.unpack('<H', f.read(2))[0]
    assert machine == 0x8664, 'not x86-64 (machine=0x%04x)' % machine
    f.seek(size - 12)
    pck_size, _pad, magic = struct.unpack('<II4s', f.read(12))
    assert magic == b'GDPC', 'no embedded PCK trailer'
    f.seek(size - 12 - pck_size)
    assert f.read(4) == b'GDPC', 'embedded PCK start magic mismatch'
# A PCK of only a few MB would mean the glTF models never made it in as real
# binaries (i.e. LFS pointers survived into the build).
assert pck_size > 50 * 1024 * 1024, 'embedded PCK only %d bytes - models missing' % pck_size
print('artefact check : PE x86-64, embedded PCK %.1f MB (models present)' % (pck_size / 1048576.0))
PY

say "done"
say "next: gh release create v$VERSION build/$ARTIFACT $(basename "$BUNDLE") build/SHA256SUMS"
