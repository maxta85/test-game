#!/usr/bin/env python3
"""Acceptance checks for the street drive, plus the mutation self-test that proves
they actually fire.

Why this file exists
--------------------
Three separate projects in this repo shipped a "green" harness that could not catch
the defect it existed to catch. The failure modes are now encoded here as checks
that must be *demonstrably* fatal:

1. A render that silently no-ops writes no frame, exits 0, and the stale PNG from
   the previous run is measured again as if it were a new result. Guard: each
   frame is deleted before rendering, and its absence afterwards is fatal.
2. Two byte-identical frames mean the camera did not move (a driver node was
   silently re-asserting its own transform). Four identical PNGs once passed as
   "four poses captured". Guard: md5 every frame, fatal on any duplicate.
3. A telemetry header declaring 10 columns over 9-field rows is a file that lies
   about its own format, and nothing reads the header width so it survives review.
   Guard: every row's field count is compared to the header's, per row.

The self-test does not assert that these checks exist. It writes deliberately
broken fixtures into a scratch directory, runs this file's own checkers over
them, and requires each to FAIL. A checker that cannot fail on a known-broken
input is decoration, so if any mutation survives, the self-test itself exits
nonzero with the word "untrustworthy" in it.

Usage: owner_checks.py <frames|csv|upshift|selftest> [dir]
"""

import hashlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

FRAME_NAMES = ["street-frame-0%d" % i for i in range(1, 5)]
CSV_NAME = "telemetry.csv"
GEAR_NAME = "gearchanges.csv"
TELEMETRY_MIN_ROWS = 5

# The gearbox under test. Sourced from Vehicles/car_spec.gd rather than hardcoded,
# because a threshold copy that drifts from the vehicle spec is a check that
# silently stops meaning anything.
SPEC_PATH = os.path.join(ROOT, "Vehicles", "car_spec.gd")
ROSTER_PATH = os.path.join(ROOT, "Vehicles", "car_db.gd")


class Failure(Exception):
    pass


def note(msg):
    sys.stdout.write("  %s\n" % msg)


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def spec_shift_up_rpm():
    """shift_up_rpm from the CarSpec class default, not copied."""
    return _scan_shift_rpm(SPEC_PATH)


def roster_shift_up_rpms():
    """Every per-car shift_up_rpm in the roster, which is what a spawned car uses.

    The CarSpec CLASS default is not the number a car drives with: the roster entry
    overrides it. Reading only the class default silently checks the gearbox against
    a threshold the gearbox never used - 6600 in the class against 6800 on the car
    under test, which is a 200 rpm gap big enough to invent failures.
    """
    return _scan_shift_rpm(ROSTER_PATH, all_values=True)


def _scan_shift_rpm(path, all_values=False):
    found = []
    with open(path) as f:
        for line in f:
            if "shift_up_rpm" not in line:
                continue
            # The value is whatever follows the key. Taking the first number on the
            # line instead would pick up a neighbouring key's value - car_db.gd keeps
            # final_drive, shift_time and shift_up_rpm on one line, so the first
            # number there is the final drive.
            tail = line.split("shift_up_rpm", 1)[1]
            for token in tail.replace("=", " ").replace(",", " ").split():
                try:
                    val = float(token)
                except ValueError:
                    continue
                found.append(val)
                if not all_values:
                    return val
                break
    if not found:
        raise Failure("shift_up_rpm not found in %s" % path)
    return found


# --------------------------------------------------------------- frames
def check_frames(d):
    paths = [os.path.join(d, n + ".png") for n in FRAME_NAMES]
    missing = [p for p in paths if not (os.path.isfile(p) and os.path.getsize(p) > 0)]
    if missing:
        raise Failure("missing or empty frame(s): %s" % ", ".join(
            os.path.basename(p) for p in missing))
    sums = {}
    for p in paths:
        sums[os.path.basename(p)] = md5(p)
    seen = {}
    for name, digest in sorted(sums.items()):
        note("md5 %s  %s" % (digest, name))
        if digest in seen:
            raise Failure("%s and %s are byte-identical (md5 %s) - the camera did "
                          "not move between those poses" % (seen[digest], name, digest))
        seen[digest] = name
    return "%d frames, all distinct" % len(paths)


# --------------------------------------------------------------- telemetry csv
def _rows(path):
    with open(path) as f:
        lines = [l.rstrip("\n") for l in f if l.strip() != ""]
    if not lines:
        raise Failure("%s is empty" % os.path.basename(path))
    return lines[0].split(","), [l.split(",") for l in lines[1:]]


def check_csv(d):
    path = os.path.join(d, CSV_NAME)
    if not (os.path.isfile(path) and os.path.getsize(path) > 0):
        raise Failure("missing or empty %s" % CSV_NAME)
    header, rows = _rows(path)
    if len(header) < 2:
        raise Failure("%s header declares %d column(s)" % (CSV_NAME, len(header)))
    if len(set(header)) != len(header):
        raise Failure("%s header has duplicate column names: %s" % (CSV_NAME, header))
    for i, r in enumerate(rows):
        if len(r) != len(header):
            raise Failure("%s row %d has %d fields, header declares %d - the file "
                          "does not match its own header" % (CSV_NAME, i, len(r), len(header)))
    if len(rows) < TELEMETRY_MIN_ROWS:
        raise Failure("%s has %d data row(s), expected at least %d - the drive did "
                      "not produce a usable trace" % (CSV_NAME, len(rows), TELEMETRY_MIN_ROWS))
    note("%d rows x %d columns, every row width == header width" % (len(rows), len(header)))
    return "%d rows x %d cols" % (len(rows), len(header))


# --------------------------------------------------------------- gear changes
def check_upshift(d):
    class_limit = spec_shift_up_rpm()
    roster = roster_shift_up_rpms()
    note("shift_up_rpm: CarSpec class default = %.0f, roster per-car values = %s"
         % (class_limit, ", ".join("%.0f" % v for v in sorted(set(roster)))))
    path = os.path.join(d, GEAR_NAME)
    if not (os.path.isfile(path) and os.path.getsize(path) > 0):
        raise Failure("missing or empty %s - no gear changes were recorded" % GEAR_NAME)
    header, rows = _rows(path)
    for need in ("to_gear", "from_gear", "road_rpm", "engine_rpm", "kmh", "shift_up_rpm", "kind"):
        if need not in header:
            raise Failure("%s has no %r column (has: %s)" % (GEAR_NAME, need, ",".join(header)))
    idx = {name: header.index(name) for name in header}
    for i, r in enumerate(rows):
        if len(r) != len(header):
            raise Failure("%s row %d has %d fields, header declares %d" % (
                GEAR_NAME, i, len(r), len(header)))
    ups = 0
    unresolved = []
    judged = 0
    for i, r in enumerate(rows):
        # The gearbox used the limit recorded on the row. It is cross-checked
        # against both sources so a drifted threshold cannot quietly pass.
        row_limit = float(r[idx["shift_up_rpm"]])
        known = [class_limit] + roster
        if not any(abs(row_limit - v) <= 1e-6 for v in known):
            raise Failure("row %d declares shift_up_rpm=%.0f, which matches neither the "
                          "CarSpec class default (%.0f) nor any roster value (%s)"
                          % (i, row_limit, class_limit,
                             ", ".join("%.0f" % v for v in sorted(set(roster)))))
        limit = row_limit
        if r[idx["kind"]].strip() != "upshift":
            continue
    ups = 0
    for i, r in enumerate(rows):
        if r[idx["kind"]].strip() != "upshift":
            continue
        ups += 1
        frm, to = int(r[idx["from_gear"]]), int(r[idx["to_gear"]])
        road = float(r[idx["road_rpm"]])
        eng = float(r[idx["engine_rpm"]])
        kmh = float(r[idx["kmh"]])
        band = float(r[idx["one_frame_rpm"]]) if "one_frame_rpm" in idx else 0.0
        # A band wider than the threshold is not a sampling limit, it is a measurement
        # that stopped resolving anything. It is reported as UNDETERMINED, which is
        # neither a pass nor a failure: claiming the gearbox is verified here would be
        # a lie, and claiming it is broken would be a worse one.
        if band > limit:
            unresolved.append("row %d: 1->%d decision sample %.0f rpm, threshold %.0f, "
                              "one-frame band %.0f rpm" % (i, to, road, limit, band))
            note("  UNDETERMINED row %d: band %.0f rpm exceeds the %.0f rpm threshold"
                 % (i, band, limit))
            continue
        note("upshift %d->%d road_rpm=%.0f engine_rpm=%.0f %.1f km/h (1-frame band %.0f)"
             % (frm, to, road, eng, kmh, band))
        if to <= frm:
            raise Failure("row %d is labelled upshift but goes %d->%d" % (i, frm, to))
        if road > limit:
            judged += 1
            continue
        # The decision rpm is only observable through a per-frame sample, so the
        # last sample before the change is a LOWER BOUND on what auto_shift saw.
        # Inside one frame of travel the truth is unresolvable at this sampling rate
        # and reporting a failure there would be inventing a defect. The band comes
        # from the recorded one-frame delta, not from a constant chosen to pass.
        if road + band > limit:
            note("  UNDETERMINED: decision sample %.0f vs limit %.0f, but one frame of "
                 "travel here is %.0f rpm - unresolvable at this sampling rate"
                 % (road, limit, band))
            unresolved.append("row %d: decision %.0f vs limit %.0f, band %.0f rpm"
                              % (i, road, limit, band))
            continue
        judged += 1
        raise Failure("row %d: upshift %d->%d happened at road_rpm=%.0f, which is not "
                      "above shift_up_rpm=%.0f even one frame of travel later "
                      "(%.0f rpm, engine_rpm=%.0f, %.1f km/h) - the gearbox changed up "
                      "too early" % (i, frm, to, road, limit, band, eng, kmh))
    note("%d upshift(s): %d judged above threshold, %d unresolvable"
         % (ups, judged, len(unresolved)))
    if unresolved and not judged:
        return ("UNDETERMINED: %d upshift(s), none resolvable at this sampling rate "
                "(%s)" % (ups, "; ".join(unresolved)))
    if unresolved:
        return ("%d gear change(s), %d upshift(s) judged (none early), %d unresolvable "
                "at this sampling rate" % (len(rows), judged, len(unresolved)))
    return "%d gear change(s), %d upshift(s) all above the rpm the gearbox used" % (
        len(rows), judged)


# --------------------------------------------------------------- mutations
def _fixture_frames(d, identical=False, empty=False):
    os.makedirs(d, exist_ok=True)
    # A 1x1 PNG, repeated. Each frame gets a distinct pixel value unless the
    # duplicate mutation is being built, in which case two of them collide.
    for i, name in enumerate(FRAME_NAMES):
        out = os.path.join(d, name + ".png")
        if empty and i == 2:
            continue
        subprocess.run(["convert", "-size", "4x4", "xc:rgb(%d,%d,0)" % (i * 40, 20), out],
                       check=True)
    if identical:
        shutil.copyfile(os.path.join(d, FRAME_NAMES[0] + ".png"),
                        os.path.join(d, FRAME_NAMES[1] + ".png"))
    return d


def _fixture_csv(d, short_row=False):
    os.makedirs(d, exist_ok=True)
    header = "t,s,kmh,gear,rpm,slip_rad,lat_m,half_width,steer,x,z"
    rows = ["0.00,0.0,0.0,1,850,0.0,0.0,5.0,0.0,0.0,0.0"]
    for i in range(1, 8):
        rows.append("%.2f,%.1f,%.1f,%d,%.0f,0.00,0.00,5.0,0.00,%.1f,%.1f"
                    % (i * 0.5, i * 2.0, i * 6.0, 1 + i % 3, 900 + i * 400, i * 3.0, i * 1.0))
    if short_row:
        # Row 3 drops the last field: the exact defect that a declared-width
        # header hides. Without a per-row comparison this file reads as data.
        rows[3] = ",".join(rows[3].split(",")[:-1])
    with open(os.path.join(d, CSV_NAME), "w") as f:
        f.write(header + "\n" + "\n".join(rows) + "\n")
    return d


def _fixture_gears(d, bad_upshift=False, near_miss=False):
    os.makedirs(d, exist_ok=True)
    limit = min(roster_shift_up_rpms())
    header = ("t,from_gear,to_gear,road_rpm,road_rpm_after,one_frame_rpm,engine_rpm,"
              "kmh,shift_up_rpm,kind")
    rows = [
        "0.50,1,2,6800.0,6790.0,40.0,6450.0,12.5,%.1f,upshift" % limit,
        "1.40,2,3,7100.0,7090.0,45.0,6400.0,22.0,%.1f,upshift" % limit,
        "3.10,3,2,2300.0,2310.0,40.0,3200.0,48.0,%.1f,downshift" % limit,
    ]
    if near_miss:
        # Only 300 rpm short of the limit this fixture declares, while one frame of
        # travel at this speed is worth 40 rpm, so the sampling band cannot rescue it.
        # If the band were a loophole, this row would pass. The value is derived from
        # the fixture's own limit so it stays a near miss if that limit ever changes.
        rows.append("2.50,2,3,%.1f,%.1f,40.0,6000.0,5.0,%.1f,upshift"
                    % (limit - 300.0, limit - 260.0, limit))
    if bad_upshift:
        # An upshift recorded at 900 road rpm - far below the threshold, and far
        # below it by more than one frame of travel, so the sampling band cannot
        # explain it. The engine rpm in this row is HIGH, which is exactly the shape
        # that fools a check reading the tacho instead of the road-derived rpm.
        rows.append("2.00,2,3,900.0,1200.0,300.0,6100.0,4.0,%.1f,upshift" % limit)
    with open(os.path.join(d, GEAR_NAME), "w") as f:
        f.write(header + "\n" + "\n".join(rows) + "\n")
    return d


MUTATIONS = [
    ("two byte-identical frames", "frames", dict(identical=True),
     "byte-identical", "the camera did not move"),
    ("a frame that never rendered", "frames", dict(empty=True),
     "missing or empty frame", "a stale PNG would be measured as new data"),
    ("a telemetry row one field short", "csv", dict(short_row=True),
     "does not match its own header", "the file lies about its format"),
    ("an upshift below the shift rpm", "upshift", dict(bad_upshift=True),
     "changed up too early", "the gearbox upshifts under threshold"),
    ("an upshift just under the limit", "upshift", dict(near_miss=True),
     "changed up too early",
     "the sampling band must not become a loophole for a real early upshift"),
]


def selftest():
    scratch = "/tmp/w2/owner-selftest"
    if os.path.isdir(scratch):
        shutil.rmtree(scratch)
    os.makedirs(scratch)
    print("MUTATION SELF-TEST")
    print("=" * 62)
    print("Each case writes a deliberately broken fixture, runs this file's own")
    print("checker over it, and requires the checker to FAIL. A checker that")
    print("survives its own break is decoration, so a surviving case fails here.")
    print("")

    # 0. The clean fixtures must pass first, or "caught" proves nothing.
    print("clean fixtures (must PASS):")
    clean = [("frames", "frames", {}),
             ("telemetry csv", "csv", {}),
             ("gear changes", "upshift", {})]
    for label, kind, kwargs in clean:
        d = {"frames": _fixture_frames, "csv": _fixture_csv,
             "upshift": _fixture_gears}[kind](os.path.join(scratch, "clean-" + kind), **kwargs)
        try:
            checkers[kind](d)
            print("  PASS  clean %s" % label)
        except Failure as e:
            print("  FAIL  clean %s was rejected: %s" % (label, e))
            print("")
            print("RESULT: untrustworthy - the checker rejects correct input, so it")
            print("cannot be used to judge anything. Fix that before anything else.")
            return 1
    print("")

    print("broken fixtures (each MUST be caught):")
    caught = 0
    uncaught = []
    for label, kind, kwargs, expect, why in MUTATIONS:
        d = {"frames": _fixture_frames, "csv": _fixture_csv,
             "upshift": _fixture_gears}[kind](os.path.join(scratch, "broken-%s" % label[:6]), **kwargs)
        try:
            checkers[kind](d)
            uncaught.append(label)
            print("  MISS  %-36s checker returned PASS on broken input" % label)
        except Failure as e:
            msg = str(e)
            if expect not in msg:
                uncaught.append(label)
                print("  MISS  %-36s failed for the WRONG reason: %s" % (label, msg))
            else:
                caught += 1
                print("  caught %-34s -> %s" % (label, msg))
                print("         (this is why it matters: %s)" % why)

    print("")
    print("=" * 62)
    print("caught %d of %d deliberate breaks" % (caught, len(MUTATIONS)))
    if uncaught:
        for label in uncaught:
            print("  NOT CAUGHT: %s" % label)
        print("")
        print("RESULT: untrustworthy - the harness cannot catch its own break, so a")
        print("passing run means nothing. Do not report this harness as evidence.")
        return 1
    print("RESULT: trustworthy - clean input passes, every deliberate break is caught.")
    return 0


checkers = {"frames": check_frames, "csv": check_csv, "upshift": check_upshift}


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    mode = argv[1]
    d = argv[2] if len(argv) > 2 else os.path.join(ROOT, "shots")
    if mode == "selftest":
        return selftest()
    if mode not in checkers:
        sys.stderr.write("unknown mode %r (frames|csv|upshift|selftest)\n" % mode)
        return 2
    try:
        result = checkers[mode](d)
    except Failure as e:
        sys.stdout.write("FAIL [%s] %s\n" % (mode, e))
        return 1
    # A third state, deliberately distinct from both. "undetermined" is not a soft
    # pass: nothing was proven, and a caller that treats it as ok is reporting a
    # check it never ran.
    if result.startswith("UNDETERMINED"):
        sys.stdout.write("UNDET [%s] %s\n" % (mode, result))
        return 3
    sys.stdout.write("ok   [%s] %s\n" % (mode, result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
