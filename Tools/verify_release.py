#!/usr/bin/env python3
"""Verify a built Cairns After Dark release artefact. Stdlib only, no Godot.

WHY THIS EXISTS
The release artefacts for 0.2.2 in another worktree were built from 72241d5,
eleven commits before main reached 1211ebf, so they contained neither the t73
CC0 engine samples (assets/audio/engine/*.wav) nor the t57 near-stationary slip
denominator fix. Nothing was wrong with that build; it was simply not main, and
the only thing that could have said so was the artefact itself. A file listing
cannot tell you that. So this measures the artefact.

WHAT IT CHECKS - all of it, or exit nonzero:
  1. build/CairnsAfterDark.exe exists, is a PE, and is plausibly sized. The
     exact byte count is reported, never a rounded one.
  2. Every line in build/SHA256SUMS recomputes to the digest it claims, for
     every file it names.
  3. The embedded Godot pack is located and its file table parsed: magic
     'GDPC', pack format v2, then u32 entry count, then per entry
     u32 path length / path / u64 offset / u64 size / 16-byte md5 / u16 flags.
     Header is 96 bytes; file data begins at the u64 file_base that follows the
     five u32s. Every offset and size is bounds-checked against the real file.
  4. Specific expected resources are present BY NAME - not by total - because a
     pack with the right number of entries and the wrong contents is exactly
     the failure this is for.

THE AUDIO EXTENSIONS ARE NOT .ctex
The brief for this script asked for "the .ctex files derived from
assets/audio/engine/*.wav and assets/audio/turbo/blowoff.ogg". That premise is
wrong, and asserting it would have produced a check that can never pass.
Measured in .godot/imported after `godot --headless --path . --import`, and
confirmed against the real pack file table:
    .wav -> .sample           (AudioStreamWAV import)
    .ogg -> .oggvorbisstr     (AudioStreamOggVorbis import)
    .png -> .ctex             (CompressedTexture2D import)
178 .ctex exist, all of them derived from .png - 150 from the seven car models
and 28 from playtest/road-map sources. Not one is audio. The expected names
below are the real imported paths, and the check asserts those.

USAGE
  Tools/verify_release.py                        # build/CairnsAfterDark.exe
  Tools/verify_release.py --exe PATH --sums PATH

Exit status is the entire interface. There is deliberately no --force, no
warning-only mode and no environment escape hatch: the only way to exit zero is
for every check to pass.
"""

import argparse
import hashlib
import os
import re
import struct
import subprocess
import sys

# --- expected release contents ----------------------------------------------
# Pinned to release 0.2.2 at main 1211ebf. These are the real imported resource
# names as they appear in the pack file table (res:// paths).

# t73 CC0 engine samples: .wav imports to .sample, NOT .ctex.
EXPECTED_ENGINE_SAMPLES = [
    "res://.godot/imported/idle.wav-79c2aa6f4a0ad1d5cf62eb3e8ef014fa.sample",
    "res://.godot/imported/cruise.wav-2413b25d657b752f886e99bdb167ceb7.sample",
    "res://.godot/imported/pull.wav-7ac9e42f6dcb676c7f3c067873a40a42.sample",
    "res://.godot/imported/redline.wav-35a4e93f746c4d24632c326c454eaacc.sample",
]

# Turbo blow-off: .ogg imports to .oggvorbisstr, NOT .ctex.
EXPECTED_BLOWOFF = [
    "res://.godot/imported/blowoff.ogg-170353531f5a534aa6d480244c77c7f4.oggvorbisstr",
]

# The source .import sidecars must also be packed, or the imported sample above
# is unreachable at runtime and the pack is self-inconsistent.
EXPECTED_AUDIO_SIDECARS = [
    "res://assets/audio/engine/idle.wav.import",
    "res://assets/audio/engine/cruise.wav.import",
    "res://assets/audio/engine/pull.wav.import",
    "res://assets/audio/engine/redline.wav.import",
    "res://assets/audio/turbo/blowoff.ogg.import",
]

# One named car texture per roster model. Asserted by name because a pack can
# carry the right COUNT of car textures drawn from the wrong car.
EXPECTED_CAR_CTEX = [
    "res://.godot/imported/wrx_gc8_0.png-0226b7f7dd6d96164a94f3f68bb5b21a.ctex",
    "res://.godot/imported/evo_v_0.png-4558ccce64078eecf0bd75d16105a4f0.ctex",
    "res://.godot/imported/silvia_s15_0.png-aaac9fa76c515fdd01222b4673461cb2.ctex",
    "res://.godot/imported/silvia_s13_0.png-014b98f5ec4ec6504b7e7c6ee144fd7a.ctex",
    "res://.godot/imported/supra_mk4_0.png-85c5995cd7416d4d757c4c9bf011dbd1.ctex",
    "res://.godot/imported/vt_commodore_0.png-404b0bb725de7719e96c088f319c0e4d.ctex",
]

# Car model stems; a .ctex whose source stem starts with one of these is a car
# texture. The other 28 .ctex in this pack are playtest and road-map sources.
CAR_STEMS = ("wrx_gc8", "evo_v", "silvia_s15", "silvia_s13", "supra_mk4",
             "vt_commodore")

EXPECTED_CAR_CTEX_COUNT = 150
EXPECTED_TOTAL_CTEX = 178

# A Godot 4.3 release export is the ~84 MB Windows template plus the pack.
# Anything under 50 MB is not a full export; a truncated file is the failure
# mode this floor exists for.
MIN_EXE_BYTES = 50 * 1024 * 1024

PACK_MAGIC = b"GDPC"
PACK_HEADER_BYTES = 96
PACK_FORMAT_V2 = 2


class CheckFailed(Exception):
    """A single invariant that did not hold. Collected, never raised to abort."""


def sha256_file(path, chunk=1024 * 1024):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            b = fh.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def u64(buf, off):
    return struct.unpack_from("<Q", buf, off)[0]


def u16(buf, off):
    return struct.unpack_from("<H", buf, off)[0]


def align4(x):
    return (x + 3) & ~3


def find_pack(data):
    """Locate the embedded pack by validating candidates, not by guessing.

    'GDPC' appears inside the export template as ordinary string data (7 hits in
    this artefact, one of them the last 4 bytes of the file). Only a candidate
    whose header parses AND whose whole directory is bounds-coherent is the
    pack, so every false positive is rejected on evidence.

    Returns (pack_offset, header_dict, entries) or raises CheckFailed.
    """
    filesize = len(data)
    rejected = []
    for m in re.finditer(PACK_MAGIC, data):
        off = m.start()
        if off + PACK_HEADER_BYTES > filesize:
            rejected.append((off, "header runs past EOF"))
            continue
        fmt = u32(data, off + 4)
        major, minor, patch = (u32(data, off + 8), u32(data, off + 12),
                               u32(data, off + 16))
        flags = u32(data, off + 20)
        file_base = u64(data, off + 24)
        count = u32(data, off + PACK_HEADER_BYTES)

        if fmt != PACK_FORMAT_V2:
            rejected.append((off, "pack format %d" % fmt))
            continue
        if count == 0 or count > 200000:
            rejected.append((off, "implausible entry count %d" % count))
            continue
        # File data must begin inside the artefact.
        if off + file_base > filesize:
            rejected.append((off, "file_base %d past EOF" % file_base))
            continue

        pos = off + PACK_HEADER_BYTES + 4
        entries = []
        bad = None
        for _ in range(count):
            if pos + 4 > filesize:
                bad = "directory truncated"
                break
            plen = u32(data, pos)
            pos += 4
            if pos + plen > filesize:
                bad = "path length %d past EOF" % plen
                break
            name = data[pos:pos + plen].rstrip(b"\x00").decode("utf-8", "replace")
            pos = align4(pos + plen)
            if pos + 16 + 16 + 2 > filesize:
                bad = "entry body past EOF"
                break
            eoff, esize = u64(data, pos), u64(data, pos + 8)
            md5 = data[pos + 16:pos + 32].hex()
            eflags = u16(data, pos + 32)
            pos = align4(pos + 34)
            # Bounds-check against the real artefact.
            if eoff + esize > filesize:
                bad = "entry %s ends past EOF (%d+%d > %d)" % (name, eoff,
                                                                esize, filesize)
                break
            if not name.startswith("res://"):
                bad = "entry %r is not a res:// path" % name
                break
            entries.append({"path": name, "offset": eoff, "size": esize,
                            "md5": md5, "flags": eflags})

        if bad:
            rejected.append((off, bad))
            continue
        if pos > off + file_base:
            rejected.append((off, "directory overruns file_base"))
            continue

        header = {"offset": off, "format": fmt,
                  "version": "%d.%d.%d" % (major, minor, patch),
                  "flags": flags, "file_base": file_base,
                  "declared_count": count, "dir_end": pos - off}
        return header, entries

    raise CheckFailed(
        "no valid embedded Godot pack found; %d 'GDPC' candidate(s) rejected: %s"
        % (len(rejected), "; ".join("%d: %s" % r for r in rejected[:6])))


def check_exe(path, results):
    """Existence, PE magic, plausible size. Returns (size, sha256) or None."""
    if not os.path.isfile(path):
        results.fail("exe missing", "no such file: %s" % path)
        return None
    size = os.path.getsize(path)
    if size == 0:
        results.fail("exe empty", "%s is 0 bytes" % path)
        return None
    if size < MIN_EXE_BYTES:
        results.fail("exe implausibly small",
                     "%d bytes < floor %d - truncated or wrong export?"
                     % (size, MIN_EXE_BYTES))
        return None
    with open(path, "rb") as fh:
        magic = fh.read(2)
    if magic != b"MZ":
        results.fail("exe is not a PE", "first bytes %r, expected b'MZ'" % magic)
        return None
    return size, sha256_file(path)


def check_sums(sums_path, base_dir, results):
    """Recompute every entry. Returns {basename: digest} or None."""
    if not os.path.isfile(sums_path):
        results.fail("SHA256SUMS missing", "no such file: %s" % sums_path)
        return None
    entries = []
    with open(sums_path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            # sha256sum format: "<64 hex>  <name>"
            m = re.match(r"^([0-9a-fA-F]{64})\s+(\S.*)$", line)
            if not m:
                results.fail("SHA256SUMS unparseable",
                             "line %d is not '<64 hex>  <name>': %r"
                             % (lineno, line))
                continue
            entries.append((lineno, m.group(1).lower(), m.group(2)))
    if not entries:
        results.fail("SHA256SUMS empty", "no checksum entries in %s" % sums_path)
        return None
    computed = {}
    listed = {}
    for lineno, want, name in entries:
        target = name if os.path.isabs(name) else os.path.join(base_dir, name)
        listed[os.path.basename(name)] = want
        if not os.path.isfile(target):
            results.fail("SHA256SUMS target missing",
                         "line %d names %s which does not exist" % (lineno, name))
            continue
        got = sha256_file(target)
        computed[os.path.basename(name)] = got
        if got != want:
            results.fail("SHA256SUMS mismatch",
                         "%s: listed %s, actual %s" % (name, want[:16] + "...",
                                                       got[:16] + "..."))
    return computed, listed, len(entries)


def check_pack(entries, results):
    paths = set(e["path"] for e in entries)
    missing = []

    def require(group, names):
        for n in names:
            if n not in paths:
                missing.append((group, n))

    require("engine sample", EXPECTED_ENGINE_SAMPLES)
    require("blow-off", EXPECTED_BLOWOFF)
    require("audio sidecar", EXPECTED_AUDIO_SIDECARS)
    require("car ctex", EXPECTED_CAR_CTEX)

    if missing:
        for group, n in missing:
            results.fail("expected resource missing",
                         "[%s] %s is not in the pack" % (group, n))

    car_ctex = [e["path"] for e in entries
                if e["path"].endswith(".ctex")
                and any(re.search(r"/%s(?:_|\.)" % re.escape(s), e["path"])
                        for s in CAR_STEMS)]
    all_ctex = [e for e in entries if e["path"].endswith(".ctex")]

    if len(car_ctex) != EXPECTED_CAR_CTEX_COUNT:
        results.fail("car ctex count",
                     "%d present, expected exactly %d"
                     % (len(car_ctex), EXPECTED_CAR_CTEX_COUNT))
    if len(all_ctex) != EXPECTED_TOTAL_CTEX:
        results.fail("total ctex count",
                     "%d present, expected exactly %d"
                     % (len(all_ctex), EXPECTED_TOTAL_CTEX))
    return paths, car_ctex, all_ctex, missing


def git_sha(root):
    try:
        out = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"],
                             capture_output=True, text=True, timeout=30)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return "unknown (git unavailable)"


def git_dirty(root):
    try:
        out = subprocess.run(["git", "-C", root, "status", "--porcelain",
                              "--untracked-files=no"],
                             capture_output=True, text=True, timeout=30)
        if out.returncode == 0:
            lines = [l for l in out.stdout.splitlines() if l.strip()]
            return len(lines), lines[:4]
    except (OSError, subprocess.SubprocessError):
        pass
    return -1, []


class Results(object):
    def __init__(self):
        self.failures = []
        self.rows = []

    def fail(self, check, detail):
        self.failures.append((check, detail))

    def row(self, key, value):
        self.rows.append((key, value))


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)

    ap = argparse.ArgumentParser(
        description="Verify the built release artefact (stdlib only, no Godot).")
    ap.add_argument("--exe", default=os.path.join(root, "build",
                                                  "CairnsAfterDark.exe"))
    ap.add_argument("--sums", default=os.path.join(root, "build",
                                                   "SHA256SUMS"))
    args = ap.parse_args(argv)

    r = Results()
    exe = os.path.abspath(args.exe)
    sums = os.path.abspath(args.sums)
    build_dir = os.path.dirname(exe)

    r.row("git sha (HEAD)", git_sha(root))
    ndirty, dirty_lines = git_dirty(root)
    r.row("git tracked changes",
           "%d" % ndirty if ndirty >= 0 else "unknown")
    r.row("exe", exe)

    size = sha = None
    got = check_exe(exe, r)
    if got:
        size, sha = got
    r.row("exe size (bytes)", "%d" % size if size is not None else "n/a")
    r.row("exe sha256", sha or "n/a")

    # SHA256SUMS is resolved next to the artefact, not next to this script.
    if os.path.isabs(args.sums) or os.path.exists(sums):
        sums_for_exe = sums
    else:
        sums_for_exe = os.path.join(build_dir, "SHA256SUMS")
    computed, listed, sums_lines = check_sums(sums_for_exe, build_dir, r)
    r.row("SHA256SUMS", sums_for_exe)
    r.row("SHA256SUMS entries recomputed",
          "%d of %d verified clean" % (len(computed or {}), sums_lines))
    if computed and sha:
        # Compares the digest the FILE CLAIMS against the artefact, not the
        # computed digest against itself - the latter always matches and is a
        # row that cannot fail.
        claimed = (listed or {}).get(os.path.basename(exe))
        r.row("exe digest listed in SHA256SUMS",
              "yes, matches artefact" if claimed == sha else
              ("NO - exe is not listed" if claimed is None
               else "yes but DISAGREES with artefact"))

    # Pack.
    entry_count = 0
    engine_ok = engine_bad = blow_ok = blow_bad = side_ok = side_bad = 0
    car_ctex_n = 0
    total_ctex_n = 0
    if got:
        try:
            with open(exe, "rb") as fh:
                data = fh.read()
            header, entries = find_pack(data)
            entry_count = len(entries)
            r.row("pack offset in exe", "%d" % header["offset"])
            r.row("pack format / engine",
                  "v%d / %s (flags %d, file_base %d)"
                  % (header["format"], header["version"], header["flags"],
                     header["file_base"]))
            r.row("pack declared count", "%d" % header["declared_count"])
            r.row("pack entries parsed", "%d" % entry_count)
            if entry_count != header["declared_count"]:
                r.fail("pack entry count",
                       "header declares %d, parsed %d"
                       % (header["declared_count"], entry_count))

            paths, car_ctex, all_ctex, missing = check_pack(entries, r)
            car_ctex_n = len(car_ctex)
            total_ctex_n = len(all_ctex)
            engine_ok = sum(1 for n in EXPECTED_ENGINE_SAMPLES if n in paths)
            engine_bad = len(EXPECTED_ENGINE_SAMPLES) - engine_ok
            blow_ok = sum(1 for n in EXPECTED_BLOWOFF if n in paths)
            blow_bad = len(EXPECTED_BLOWOFF) - blow_ok
            side_ok = sum(1 for n in EXPECTED_AUDIO_SIDECARS if n in paths)
            side_bad = len(EXPECTED_AUDIO_SIDECARS) - side_ok
        except CheckFailed as e:
            r.fail("pack parse", str(e))
        except (OSError, struct.error) as e:
            r.fail("pack parse", "%s: %s" % (type(e).__name__, e))

    r.row("pck entry count", "%d" % entry_count)
    r.row("engine sample .ctex/.sample present",
          "%d/%d%s" % (engine_ok, len(EXPECTED_ENGINE_SAMPLES),
                       "" if not engine_bad else "  MISSING %d" % engine_bad))
    r.row("blowoff .oggvorbisstr present",
          "%d/%d%s" % (blow_ok, len(EXPECTED_BLOWOFF),
                       "" if not blow_bad else "  MISSING %d" % blow_bad))
    r.row("audio sidecars present",
          "%d/%d%s" % (side_ok, len(EXPECTED_AUDIO_SIDECARS),
                       "" if not side_bad else "  MISSING %d" % side_bad))
    r.row("car .ctex", "%d (expected %d)" % (car_ctex_n,
                                              EXPECTED_CAR_CTEX_COUNT))
    r.row("total .ctex", "%d (expected %d)" % (total_ctex_n,
                                               EXPECTED_TOTAL_CTEX))

    # --- table ---------------------------------------------------------------
    width = max(len(k) for k, _ in r.rows)
    print("")
    print("=" * (width + 60))
    print("  Cairns After Dark - release artefact verification")
    print("=" * (width + 60))
    for k, v in r.rows:
        print("  %-*s  %s" % (width, k, v))
    if ndirty > 0:
        print("")
        print("  note: %d tracked change(s) in the worktree (artifact is stale"
              " relative to HEAD):" % ndirty)
        for l in dirty_lines:
            print("        %s" % l)
    print("-" * (width + 60))

    if r.failures:
        print("  FAIL - %d check(s) failed:" % len(r.failures))
        for check, detail in r.failures:
            print("    [%s] %s" % (check, detail))
        print("-" * (width + 60))
        print("verify_release: FAILED (%d)" % len(r.failures))
        return 1

    print("  all %d checks passed" % len(r.rows))
    print("-" * (width + 60))
    print("verify_release: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
