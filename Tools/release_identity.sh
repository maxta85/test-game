#!/usr/bin/env bash
# Prove a Windows artefact IS the binary windows/manifest.json claims it is.
#
# The failure this exists to prevent: a release built in one worktree shipped
# with a manifest describing a DIFFERENT binary - manifest 0.1.1 / v0.1.1 /
# 212294768 against a checkout saying 0.2.1 and a payload of 140877408 bytes.
# Nothing lied; the system simply could not tell the truth about itself, so
# this measures the artefact instead of trusting what was written down.
#
# Why the mismatch is not cosmetic: the installer bundles manifest.json, the
# launcher installs manifest.sha256, downloads manifest.asset from the release
# tagged manifest.tag and reports manifest.size as the expected download size.
# A manifest that disagrees with the payload ships an installer that hands the
# player the wrong build, or that fails its own checksum on first run.
#
# It is a gate, not a report. There is deliberately no --force, no warning-only
# mode and no environment escape hatch; the only way to exit zero is for every
# field to agree. Exit status is the entire interface.
#
#   Tools/release_identity.sh                      # build/CairnsAfterDark.exe vs windows/manifest.json
#   Tools/release_identity.sh path/to/Other.exe    # any artefact
#   Tools/release_identity.sh --selftest           # exercise BOTH directions
#
# Fields checked - all of them, or exit nonzero:
#   size      manifest.size              == real byte count of the artefact
#   sha256    manifest.sha256            == real SHA-256 of the artefact
#   version   manifest.version           == windows/VERSION (the one input)
#   tag       manifest.tag               == v<version>
#   asset     manifest.asset             == basename of the artefact
#   project   project.godot config/version == windows/VERSION
#
# sha256 compares case-insensitively because the launcher lowercases both
# sides before comparing; a manifest written in uppercase is still honest.
#
# windows/VERSION is the single hand-edited input for the release version.
# windows/manifest.json (via --tag), project.godot and this gate all derive
# from it, and the gate fails when any of them drift. That is what turns a
# stale copy in another worktree from a silent defect into a refused build.
#
# NOT checked, and deliberately so: export_presets.cfg's
# application/file_version and application/product_version, which read 0.1.0.0
# against a 0.2.0 release. They look like a fourth place to keep in step, but
# they are not, and measured against a real export they cannot be:
# application/modify_resources is false, so Godot never rewrites the PE version
# resource. A 0.2.1.0 preset exported a binary whose VS_FIXEDFILEINFO reads
# FileVersion=3.4.0.0 - byte-identical to the 4.3-stable export template's own
# version resource - and the string "0.2.1.0" appears nowhere in the artefact.
# Gating on a value that provably cannot reach the artefact would be theatre.
#
# The manifest IS packed into the .exe, though: windows/ is not in the preset's
# exclude_filter, so every artefact carries whatever windows/manifest.json
# happened to say in the worktree that exported it. Nothing reads that copy at
# runtime (the launcher reads the loose one bundled beside install.ps1), so it
# is inert, but it is what the audit found in the shipped binary. See
# windows/README.md.
#
# Env: none. No bypass knobs exist.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ARTIFACT="$ROOT/build/CairnsAfterDark.exe"
MANIFEST="$ROOT/windows/manifest.json"
VERSION_FILE="$ROOT/windows/VERSION"
PROJECT_FILE="$ROOT/project.godot"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- the measurement --------------------------------------------------------
# Deliberately no Godot: this has to run in CI, and it has to be able to
# answer the question without building anything.

size_of() {
  stat -c%s "$1" 2>/dev/null || wc -c < "$1" | tr -d ' '
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# One python3 process for the whole manifest. It is already a dependency of
# windows/package-windows.sh, it is stdlib, and it cannot misread a JSON
# string the way a grep or sed expression can.
manifest_fields() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as f:
        m = json.load(f)
except FileNotFoundError:
    sys.exit('manifest does not exist: %s' % path)
except OSError as e:
    sys.exit('manifest is unreadable (%s): %s' % (e, path))
except ValueError as e:
    sys.exit('manifest is not valid JSON (%s): %s' % (e, path))
if not isinstance(m, dict):
    sys.exit('manifest is not a JSON object: %s' % path)
for key in ('version', 'tag', 'asset', 'sha256', 'size'):
    value = m.get(key)
    if value is None or value == '':
        sys.exit("manifest is missing required field '%s': %s" % (key, path))
    print('%s\t%s' % (key, value))
PY
}

# --- the check --------------------------------------------------------------
# Every field is compared and every disagreement is reported, then the script
# exits nonzero. Collecting them is not leniency: one nonzero exit either way.
# A half-updated manifest is the common case, and a gate that stops at the
# first field would hide the other three.
OK_FIELDS=()
FAILED=()

bad() { # field, label-a, value-a, label-b, value-b
  FAILED+=("$1")
  printf 'FAIL: %s\n' "$1"
  printf '        %-18s %s\n' "$2" "$3"
  printf '        %-18s %s\n' "$4" "$5"
}

ok() { OK_FIELDS+=("$1"); }

check_identity() {
  OK_FIELDS=()
  FAILED=()

  [ -f "$ARTIFACT" ] || die "artefact does not exist: $ARTIFACT"
  [ -s "$ARTIFACT" ] || die "artefact is empty: $ARTIFACT"
  [ -f "$MANIFEST" ] || die "manifest does not exist: $MANIFEST"
  [ -f "$VERSION_FILE" ] || die "declared version file does not exist: $VERSION_FILE"
  [ -f "$PROJECT_FILE" ] || die "project file does not exist: $PROJECT_FILE"

  local fields
  if ! fields="$(manifest_fields "$MANIFEST")"; then
    die "manifest is unusable: $MANIFEST"
  fi

  local mf_version='' mf_tag='' mf_asset='' mf_sha='' mf_size='' key value
  while IFS=$'\t' read -r key value; do
    case "$key" in
      version) mf_version=$value ;;
      tag)     mf_tag=$value ;;
      asset)   mf_asset=$value ;;
      sha256)  mf_sha=$value ;;
      size)    mf_size=$value ;;
    esac
  done <<< "$fields"

  local declared real_size real_sha
  declared="$(tr -d '[:space:]' < "$VERSION_FILE")"
  [ -n "$declared" ] || die "declared version file is empty: $VERSION_FILE"

  # project.godot's config/version. One line, one grep, no parser: the value is
  # a quoted scalar on a line of its own and Godot rewrites the file if the
  # shape ever changes, so an unreadable shape shows up as a missing value and
  # is reported as a mismatch rather than silently skipped.
  local project_version
  project_version="$(sed -n 's/^config\/version="\(.*\)"$/\1/p' "$PROJECT_FILE" | head -n 1)"

  real_size="$(size_of "$ARTIFACT")"
  real_sha="$(sha256_of "$ARTIFACT")"

  if [ "$mf_size" = "$real_size" ]; then ok size
  else bad size 'manifest:' "$mf_size" 'artefact:' "$real_size"; fi

  if [ "${mf_sha,,}" = "${real_sha,,}" ]; then ok sha256
  else bad sha256 'manifest:' "$mf_sha" 'artefact:' "$real_sha"; fi

  if [ "$mf_version" = "$declared" ]; then ok version
  else bad version 'manifest:' "$mf_version" "$(basename "$VERSION_FILE"):" "$declared"; fi

  if [ "$mf_tag" = "v$declared" ]; then ok tag
  else bad tag 'manifest:' "$mf_tag" 'expected:' "v$declared"; fi

  if [ "$mf_asset" = "$(basename "$ARTIFACT")" ]; then ok asset
  else bad asset 'manifest:' "$mf_asset" 'artefact:' "$(basename "$ARTIFACT")"; fi

  if [ -n "$project_version" ] && [ "$project_version" = "$declared" ]; then ok project
  else bad project 'project.godot:' "${project_version:-<unset>}" \
                   "$(basename "$VERSION_FILE"):" "$declared"; fi

  if [ "${#FAILED[@]}" -gt 0 ]; then
    local joined
    printf -v joined '%s,' "${FAILED[@]}"
    printf 'release identity: FAILED - %d of %d fields disagree: %s\n' \
      "${#FAILED[@]}" "$(( ${#OK_FIELDS[@]} + ${#FAILED[@]} ))" "${joined%,}"
    return 1
  fi
  printf 'release identity: OK - %s all agree (%s, %s bytes)\n' \
    "${#OK_FIELDS[@]}" "$(basename "$ARTIFACT")" "$real_size"
  return 0
}

# --- selftest ---------------------------------------------------------------
# Both directions, or the selftest itself fails. A checker that only ever
# reports success is the exact failure mode this project keeps shipping, so the
# negative cases are the point, not the padding.
SELFTEST_TMP=""
PASSED=0
CASES=0

pass()  { printf '  ok    %s\n' "$*"; PASSED=$((PASSED+1)); CASES=$((CASES+1)); }
broken(){ printf '  FAIL  %s\n' "$*"; CASES=$((CASES+1)); }

# Captures both output and status without ever aborting the caller.
LAST_OUTPUT=""
LAST_STATUS=0
run_identity() {
  if LAST_OUTPUT="$(check_identity 2>&1)"; then LAST_STATUS=0; else LAST_STATUS=1; fi
}

expect_pass() { # description
  run_identity
  if [ "$LAST_STATUS" = 0 ]; then
    pass "$1 (exit 0)"
  else
    broken "$1 - expected exit 0, got exit $LAST_STATUS"
    printf '%s\n' "$LAST_OUTPUT" | sed 's/^/          | /'
  fi
}

expect_fail() { # description, needle...
  local desc="$1"; shift
  run_identity
  if [ "$LAST_STATUS" = 0 ]; then
    broken "$desc - expected NONZERO, got exit 0 (checker is not a gate)"
    return
  fi
  local needle missing=''
  for needle in "$@"; do
    case "$LAST_OUTPUT" in
      *"$needle"*) ;;
      *) missing="$missing [$needle]" ;;
    esac
  done
  if [ -n "$missing" ]; then
    broken "$desc - exit $LAST_STATUS but output never named:$missing"
    printf '%s\n' "$LAST_OUTPUT" | sed 's/^/          | /'
  else
    pass "$desc (exit $LAST_STATUS, named the field and both values)"
  fi
}

fixture_manifest() { # path version tag asset sha size
  # A quoted heredoc so the \\ in the Windows saves_path survives as JSON
  # rather than being eaten the way a bash-expanded heredoc eats it.
  cat > "$1" <<JSON
{
  "game": "Cairns After Dark",
  "version": "$2",
  "tag": "$3",
  "asset": "$4",
  "sha256": "$5",
  "size": $6,
  "repo": "maxta85/test-game",
  "releases_url": "https://github.com/maxta85/test-game/releases",
  "saves_path": "%APPDATA%\\\\CairnsAfterDark"
}
JSON
}

selftest() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required (and is already a dependency of windows/package-windows.sh)"

  SELFTEST_TMP="$(mktemp -d)"
  trap 'rm -rf "$SELFTEST_TMP"' EXIT

  # Deliberately 0.9.9: if the checker ever stopped reading the declared
  # version file and started trusting a constant, the positive case would stop
  # being a real check.
  local ver="0.9.9" tag="v0.9.9" asset="CairnsAfterDark.exe"
  local exe="$SELFTEST_TMP/$asset"
  local size sha
  mkdir -p "$SELFTEST_TMP/a" "$SELFTEST_TMP/b"

  # A plausible PE stub with random bytes: unique digest per run, so passing
  # cannot come from the checker recognising a fixture.
  { printf 'MZ'; head -c 65535 /dev/urandom; } > "$exe"
  size="$(size_of "$exe")"
  sha="$(sha256_of "$exe")"

  local man="$SELFTEST_TMP/a/manifest.json" vfile="$SELFTEST_TMP/a/VERSION"
  local proj="$SELFTEST_TMP/a/project.godot"
  printf '%s\n' "$ver" > "$vfile"
  cat > "$proj" <<GODOT
; Engine configuration file.
config_version=5

config/name="Cairns After Dark"
config/version="$ver"
GODOT
  fixture_manifest "$man" "$ver" "$tag" "$asset" "$sha" "$size"

  ARTIFACT="$exe"; MANIFEST="$man"; VERSION_FILE="$vfile"; PROJECT_FILE="$proj"

  say "release_identity selftest"

  # --- direction 1: a matching pair must pass -------------------------------
  expect_pass "matching exe + manifest"

  # Same pair, uppercase digest. The launcher lowercases both sides before
  # comparing, so an uppercase manifest is honest, not a mismatch.
  python3 - "$man" "$sha" <<'PY'
import json, sys
p, sha = sys.argv[1], sys.argv[2].upper()
m = json.load(open(p, encoding='utf-8'))
m['sha256'] = sha
json.dump(m, open(p, 'w', encoding='utf-8'), indent=2)
PY
  expect_pass "uppercase sha256 still matches (launcher lowercases)"
  fixture_manifest "$man" "$ver" "$tag" "$asset" "$sha" "$size"

  # --- direction 2: each field, mutated one at a time ----------------------
  # One field per case, so a checker that only ever compared size+sha cannot
  # pass this run.

  fixture_manifest "$man" "$ver" "$tag" "$asset" "$sha" "$((size+1))"
  expect_fail "size mismatch is refused" "size" "$size" "$((size+1))"

  fixture_manifest "$man" "$ver" "$tag" "$asset" \
    "0000000000000000000000000000000000000000000000000000000000000000" "$size"
  expect_fail "sha256 mismatch is refused" "sha256" "$sha"

  fixture_manifest "$man" "0.9.8" "v0.9.8" "$asset" "$sha" "$size"
  expect_fail "version drift against windows/VERSION is refused" "version" "0.9.8" "$ver"

  fixture_manifest "$man" "$ver" "v0.9.8" "$asset" "$sha" "$size"
  expect_fail "tag drift is refused" "tag" "v0.9.8" "v$ver"

  fixture_manifest "$man" "$ver" "$tag" "SomeOtherGame.exe" "$sha" "$size"
  expect_fail "asset name drift is refused" "asset" "SomeOtherGame.exe"

  # The exact shape of the defect being fixed: a worktree whose manifest was
  # bumped by hand in someone else's checkout, and whose payload is untouched.
  cat > "$proj" <<'GODOT'
config_version=5
config/version="0.2.1"
GODOT
  expect_fail "project.godot version drift is refused" "project" "0.2.1" "$ver"
  cat > "$proj" <<GODOT
config_version=5
config/version="$ver"
GODOT

  # The combined case from the real incident: stale size AND stale digest.
  fixture_manifest "$man" "0.1.1" "v0.1.1" "$asset" \
    "deadbeef00000000000000000000000000000000000000000000000000000000" \
    "$((size+7000))"
  expect_fail "combined stale manifest names every offending field" \
    "size" "sha256" "version" "0.1.1" "v0.1.1"

  # --- direction 2, continued: bad inputs, not just bad values ------------
  rm -f "$man"
  expect_fail "missing manifest is refused" "manifest"

  printf '{ "version": ' > "$man"
  expect_fail "malformed manifest JSON is refused" "manifest"

  cat > "$man" <<'JSON'
{"game": "Cairns After Dark", "version": "0.9.9", "tag": "v0.9.9"}
JSON
  expect_fail "manifest missing required fields is refused" "manifest"

  fixture_manifest "$man" "$ver" "$tag" "$asset" "$sha" "$size"
  mv "$exe" "$SELFTEST_TMP/gone.exe"
  expect_fail "missing artefact is refused" "artefact"
  mv "$SELFTEST_TMP/gone.exe" "$exe"

  rm -f "$vfile"
  expect_fail "missing windows/VERSION is refused" "VERSION"
  printf '%s\n' "$ver" > "$vfile"

  # --- the wiring, statically ---------------------------------------------
  # A gate that exists but is never called, or is called inside the SKIP_TESTS
  # gate, is not a gate. Checked here because this is the only place the
  # packaging script is loaded.
  local pack="$ROOT/windows/package-windows.sh" gate_line skip_line copy_line zip_line skip_block
  if [ ! -f "$pack" ]; then
    broken "windows/package-windows.sh not found - cannot check the wiring"
  else
    # || true on every lookup: an absent match is a finding to report, not a
    # pipeline failure to abort the selftest on with no diagnostic.
    #
    # The gate is the first line that mentions the script AND is neither a
    # comment nor an assignment - a line that merely defines
    # IDENTITY_CHECK="Tools/release_identity.sh" is wiring on paper, not a
    # check, and matching it would make this pass on an unwired package step.
    gate_line="$(awk '/release_identity\.sh/ && !/^[[:space:]]*#/ && !/=/ {print NR; exit}' "$pack" || true)"
    skip_line="$(awk '/if \[ "\$\{SKIP_TESTS/{print NR; exit}' "$pack" || true)"
    copy_line="$(grep -n 'cp windows/manifest.json' "$pack" | head -n 1 | cut -d: -f1 || true)"
    zip_line="$(grep -n 'zipfile.ZipFile' "$pack" | head -n 1 | cut -d: -f1 || true)"
    # The literal block between `if [ "${SKIP_TESTS` and its closing `fi`. The
    # gate is unskippable if and only if the string never appears in there.
    skip_block="$(awk '/if \[ "\$\{SKIP_TESTS/,/^fi$/' "$pack" || true)"
    if [ -z "$gate_line" ]; then
      broken "package-windows.sh never calls release_identity.sh"
    elif [ -z "$copy_line" ] || [ -z "$zip_line" ]; then
      broken "could not locate the bundle write in package-windows.sh"
    elif [ -z "$skip_line" ]; then
      broken "could not locate the SKIP_TESTS block in package-windows.sh - cannot prove the gate is outside it"
    elif [ "$gate_line" -ge "$copy_line" ] || [ "$gate_line" -ge "$zip_line" ]; then
      broken "identity gate (line $gate_line) is not before the manifest bundle (line $copy_line) and the zip (line $zip_line)"
    elif case "$skip_block" in *release_identity*) true ;; *) false ;; esac; then
      broken "the identity check is wired inside the SKIP_TESTS block"
    else
      pass "package-windows.sh gates the bundle (line $gate_line, before the manifest copy at $copy_line and the zip at $zip_line) and is not inside the SKIP_TESTS block at line $skip_line"
    fi
  fi

  rm -rf "$SELFTEST_TMP"; SELFTEST_TMP=""

  printf '\n%s selftests, %d behaved correctly\n' "$CASES" "$PASSED"
  if [ "$CASES" -eq "$PASSED" ]; then
    printf 'selftest OK\n'
    return 0
  fi
  printf 'selftest FAILED: %d of %d cases did not behave as required\n' \
    "$((CASES-PASSED))" "$CASES" >&2
  return 1
}

# --- entry point ------------------------------------------------------------
DO_SELFTEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest)  DO_SELFTEST=1 ;;
    --manifest=*)     MANIFEST="${1#*=}" ;;
    --manifest)       shift; [ $# -gt 0 ] || die "--manifest needs a path"; MANIFEST="$1" ;;
    --version-file=*) VERSION_FILE="${1#*=}" ;;
    --version-file)   shift; [ $# -gt 0 ] || die "--version-file needs a path"; VERSION_FILE="$1" ;;
    --project-file=*) PROJECT_FILE="${1#*=}" ;;
    --project-file)   shift; [ $# -gt 0 ] || die "--project-file needs a path"; PROJECT_FILE="$1" ;;
    -h|--help)  usage; exit 0 ;;
    -*)          die "unknown option: $1 (try --help)" ;;
    *)           ARTIFACT="$1" ;;
  esac
  shift
done

if [ "$DO_SELFTEST" = 1 ]; then
  selftest
else
  check_identity
fi
