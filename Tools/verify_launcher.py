#!/usr/bin/env python3
"""Assert the Windows launcher's contract, on any machine, with no Windows.

    python3 Tools/verify_launcher.py

The launcher in windows/ is the only part of this project a player ever runs,
and for 772 lines it had never been parsed, let alone executed. This is the
check that stops it being a very long comment: everything about it that *can*
be decided without Windows is decided here, on every checkout, in CI.

Deliberately stdlib only (tomllib, hashlib, json, re, urllib) so it runs
anywhere python3 does. Optional extras degrade to SKIP, never to a silent
green: a machine with no PowerShell gets "parse check skipped", and a machine
with no network gets "release check skipped" - both printed, so nobody can
mistake a skip for a pass.

Exit 0 = every check that could run, passed.
Exit 1 = something is broken, and the failing line says what.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WIN = ROOT / "windows"
INSTALL_PS1 = WIN / "install.ps1"
MANIFEST = WIN / "manifest.json"
BAT = WIN / "CairnsAfterDark.bat"
GUI_PS1 = WIN / "launcher-gui.ps1"
GUI_BAT = WIN / "CairnsAfterDark-GUI.bat"
README = WIN / "README.md"
PRESETS = ROOT / "export_presets.cfg"
PROJECT = ROOT / "project.godot"

# Directories that are generated, not source. A path inside one of these is
# allowed to be missing or untracked, because nothing is ever supposed to have
# committed it. Anything else that a doc points at must be a real, tracked file.
GENERATED_DIRS = ("build/", ".godot/", "shots/")

# Network is optional so this gate is usable on a plane. VERIFY_LAUNCHER_OFFLINE=1
# skips it explicitly; without network it is skipped with a loud note.
OFFLINE = os.environ.get("VERIFY_LAUNCHER_OFFLINE") == "1"
NET_TIMEOUT = 20

passed, failed, skipped = 0, 0, 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print("  [PASS] %s%s" % (name, ("  " + detail) if detail else ""))
    else:
        failed += 1
        print("  [FAIL] %s%s" % (name, ("  " + detail) if detail else ""))
    return ok


def skip(name, why):
    global skipped
    skipped += 1
    print("  [SKIP] %s  (%s)" % (name, why))


def head(title):
    print("\n== %s" % title)


def read(path):
    return path.read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------------------
# Optional toolchains. Found once, used by the checks that need them.
# ---------------------------------------------------------------------------


def find_pwsh():
    for cand in (
        os.environ.get("PWSH"),
        shutil.which("pwsh"),
        shutil.which("powershell"),
        str(ROOT / "build" / "pwsh" / "pwsh"),
    ):
        if cand and Path(cand).exists():
            return cand
    return None


def find_godot():
    for cand in (os.environ.get("GODOT"), shutil.which("godot"), "/home/coder/tools/godot"):
        if cand and Path(cand).exists() and os.access(cand, os.X_OK):
            return cand
    return None


def git_ls_files():
    """Paths git tracks, or None if this is not a git checkout."""
    try:
        out = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z"],
            capture_output=True, text=True, timeout=30, check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return {p for p in out.split("\0") if p}


# ---------------------------------------------------------------------------
# 1. The files exist, and they are in the repository
# ---------------------------------------------------------------------------


def check_files():
    head("files")
    for p in (INSTALL_PS1, MANIFEST, BAT, GUI_PS1, GUI_BAT, README, PRESETS, PROJECT,
              WIN / "package-windows.sh"):
        check("%s exists" % p.relative_to(ROOT), p.is_file())

    tracked = git_ls_files()
    if tracked is None:
        skip("files are git-tracked", "not a git checkout")
        return
    for p in sorted(WIN.iterdir()):
        if not p.is_file():
            continue
        rel = p.relative_to(ROOT).as_posix()
        # build/ is gitignored, so build/package-windows.sh existed only on the
        # machine that wrote it while the README pointed at it as if it shipped.
        # That is the whole class of bug this check exists for.
        check("%s is committed" % rel, rel in tracked,
              "" if rel in tracked else "on disk but untracked - nobody else has it")
    check("export_presets.cfg is committed", "export_presets.cfg" in tracked)


# ---------------------------------------------------------------------------
# 2. Every path the launcher or its docs point at actually resolves
# ---------------------------------------------------------------------------


def referenced_paths():
    """Repo-relative paths mentioned in the launcher's own files.

    A reference only counts if its first segment is a real top-level entry in
    the repo. That one rule is what makes this usable: it drops `Games` (out of
    `C:\\Games\\...`), `assets.githubusercontent.com` (out of a redirect URL),
    `GameExeName` (a PowerShell variable) and `windows_release_x86_64.exe` (a
    file inside the export templates), and keeps `windows/install.ps1`. A
    noisy checker gets ignored; a quiet one that names the dead reference is
    the whole point.
    """
    top = {p.name for p in ROOT.iterdir()} | {"export_presets.cfg", "project.godot"}
    pat = re.compile(
        r"(?<![\w./-])((?:windows|build|Tools|Tests|World|Game|UI|AI|Audio|Systems|artkit|Vehicles|assets"
        r"|export_presets\.cfg|project\.godot)[/\w.-]*)")
    seen = []
    for src in (README, INSTALL_PS1, BAT, GUI_PS1, GUI_BAT, WIN / "package-windows.sh"):
        if not src.is_file():
            continue
        for line in read(src).splitlines():
            for m in pat.finditer(line):
                ref = m.group(1).rstrip(".,;:)`\"'")
                if any(c in ref for c in "%$*~\\") or ref.split("/")[0] not in top:
                    continue
                if (src, ref) not in seen:
                    seen.append((src, ref))
    return seen


def check_referenced_paths():
    head("referenced paths resolve")
    tracked = git_ls_files()
    for src, ref in referenced_paths():
        target = ROOT / ref
        exists = target.exists()
        if not exists and ref.startswith(GENERATED_DIRS):
            continue
        if not exists:
            check("%s -> %s" % (src.relative_to(ROOT), ref), False, "does not exist")
            continue
        if tracked is not None and not ref.endswith("/") and "/" in ref:
            # build/ output is generated, everything else a doc points at is source.
            if not ref.startswith(GENERATED_DIRS):
                check("%s -> %s" % (src.relative_to(ROOT), ref), ref in tracked,
                      "" if ref in tracked else "untracked - gitignored, so it ships to nobody")


# ---------------------------------------------------------------------------
# 3. install.ps1: the properties that must not regress
# ---------------------------------------------------------------------------


def check_install_ps1():
    head("install.ps1")
    src = read(INSTALL_PS1)

    check("Set-StrictMode is on", "Set-StrictMode" in src,
          "without it a typo'd manifest property silently becomes $null")
    check("Tls12 is requested", "Tls12" in src, "GitHub refuses SSL3/TLS1.0")

    # Trust boundary: the digest is compared before the file is moved into
    # place. If this ever inverts, a tampered download runs with the player's
    # privileges, which is the one thing this script must never do.
    cmp_at = src.find("checksum mismatch")
    move_at = src.find("Move-Item -LiteralPath $tmp -Destination $GameExe")
    check("payload is hash-verified before it is installed",
          cmp_at != -1 and move_at != -1 and cmp_at < move_at,
          "line %d vs %d" % (src[:cmp_at].count("\n") + 1, src[:move_at].count("\n") + 1))

    uninst = src[src.find("function Invoke-Uninstall"):src.find("# Entry point")]
    check("uninstall never deletes the save directory",
          "Remove-Item" in uninst and not re.search(r"Remove-Item[^\n]*\$SaveDir", uninst))
    # windows\install.ps1 sits one level below the repo root, so $Root is the
    # working tree. -Recurse there eats every agent's uncommitted work. The
    # guard has to be in the *refusal condition*, not merely computed: a
    # $isCheckout that nothing tests is exactly the state this check exists to
    # catch, so require the -or that actually arms it.
    check("uninstall refuses to delete a source checkout",
          bool(re.search(r"if \(\$null -eq \$resolved[^\n]*\$isCheckout\)", uninst)),
          "the recursive delete is gated on the install dir not being a checkout")

    # PowerShell 7 renamed powershell.exe to pwsh.exe. A hard-coded name makes
    # both re-launch paths silently no-op on a pwsh-only machine.
    hard = re.findall(r"Join-Path \$PSHOME 'powershell\.exe'", src)
    check("PowerShell exe name is not hard-coded to powershell.exe", not hard,
          "pwsh.exe under PowerShell 7" if not hard else "found %d" % len(hard))
    check("re-launch uses the resolved PowerShell exe", "$PowerShellExe" in src)

    # install.ps1 lives at <root>/launcher/install.ps1 in the shipped bundle and
    # at <root>/windows/install.ps1 in the checkout; both derive $Root as the
    # parent, so the remote manifest it looks for has to sit in windows/.
    check("remote manifest URL matches the repo layout",
          "raw.githubusercontent.com" in src and "/main/windows/manifest.json" in src)

    check("param() declares a default Action so a bare invocation works",
          re.search(r"\[string\]\s*\$Action\s*=\s*'Play'", src) is not None)


# ---------------------------------------------------------------------------
# 4. manifest.json: schema, and agreement with the rest of the repo
# ---------------------------------------------------------------------------


def check_manifest():
    head("manifest.json")
    try:
        m = json.loads(read(MANIFEST))
    except ValueError as e:
        check("manifest.json is valid JSON", False, str(e))
        return None
    check("manifest.json is valid JSON", True)

    for key in ("game", "version", "tag", "asset", "sha256", "size", "repo"):
        check("manifest has %r" % key, bool(m.get(key)))
    check("sha256 is 64 lowercase hex", re.fullmatch(r"[0-9a-f]{64}", str(m.get("sha256", ""))) is not None)
    check("size is a positive integer",
          str(m.get("size", "")).isdigit() and int(m.get("size", 0)) > 0,
          "%s bytes" % m.get("size"))
    check("tag is v<version>", m.get("tag") == "v%s" % m.get("version"),
          "%s / %s" % (m.get("tag"), m.get("version")))

    src = read(INSTALL_PS1)
    # install.ps1 must agree with the manifest, or the two drift and the
    # launcher downloads something the manifest never described.
    def ps_var(name):
        mm = re.search(r"\$%s\s*=\s*'([^']*)'" % name, src)
        return mm.group(1) if mm else None

    check("install.ps1 $GameExeName == manifest asset",
          ps_var("GameExeName") == m.get("asset"), "%s / %s" % (ps_var("GameExeName"), m.get("asset")))
    check("install.ps1 $DefaultRepo == manifest repo",
          ps_var("DefaultRepo") == m.get("repo"), "%s / %s" % (ps_var("DefaultRepo"), m.get("repo")))
    check("saves live outside the install dir, in both files",
          r"%APPDATA%\CairnsAfterDark" == m.get("saves_path") and "CairnsAfterDark" in src,
          str(m.get("saves_path")))

    # project.godot is the project's own version of record.
    pg = read(PROJECT)
    mm = re.search(r'config/version\s*=\s*"([^"]+)"', pg)
    check("manifest version == project.godot config/version",
          mm is not None and mm.group(1) == m.get("version"),
          "%s / %s" % (mm.group(1) if mm else "?", m.get("version")))
    check("releases_url points at the manifest repo",
          m.get("repo", "") in str(m.get("releases_url", "")))
    return m


# ---------------------------------------------------------------------------
# 5. CairnsAfterDark.bat: the double-click path
# ---------------------------------------------------------------------------


def check_bat():
    head("CairnsAfterDark.bat")
    raw = BAT.read_bytes()
    src = raw.decode("utf-8", errors="replace")

    check("is a .bat", src.startswith("@echo off"))
    check("uses CRLF line endings", b"\r\n" in raw and raw.count(b"\n") == raw.count(b"\r\n"),
          "cmd.exe is not required to cope with LF, especially around a multi-line block")
    check("finds install.ps1 next to itself", 'set "PS1=%~dp0install.ps1"' in src)
    check("finds install.ps1 in the bundle's launcher/ folder", "launcher\\install.ps1" in src)
    check("pauses when PowerShell fails", "if errorlevel 1" in src and "pause" in src)

    # The bug this file shipped with: `-Action %*` written unconditionally.
    # With no arguments %* is empty, so the command line ends in a bare
    # "-Action", PowerShell cannot bind it, and the default double-click -
    # the single most important path in the whole launcher - installed nothing.
    # The guard has to be *on that line*: a stray `if "%~1"==""` elsewhere in
    # the file is not a fix, so the nearest preceding code line is what counts.
    lines = src.splitlines()
    bad = []
    for i, line in enumerate(lines):
        if "-Action %*" not in line:
            continue
        prev = [l.strip() for l in lines[:i] if l.strip() and not l.strip().lower().startswith("rem")]
        if not prev or prev[-1] != ") else (":
            bad.append(i + 1)
    check("a bare -Action is never passed to PowerShell", not bad,
          "line %d is reachable with no arguments - a double-click cannot bind -Action" % bad[0] if bad
          else 'every -Action %* sits in the else branch of if "%~1"==""')
    return src


def check_bat_argv_with_pwsh(pwsh):
    """Prove the no-argument double-click actually binds, for real.

    install.ps1's param block is lifted into a stub that only prints what it
    got, so nothing is installed, downloaded or deleted. Both invocation forms
    from the .bat are then replayed verbatim against it.
    """
    head("CairnsAfterDark.bat -> PowerShell argument binding")
    src = read(INSTALL_PS1)
    start = src.find("param(")
    if start == -1:
        check("param() block found", False)
        return
    depth, i = 0, start + len("param") - 1
    while i < len(src):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                break
        i += 1
    block = src[start + len("param"):i + 1]

    with tempfile.TemporaryDirectory() as td:
        stub = Path(td) / "stub.ps1"
        stub.write_text(
            "[CmdletBinding()]\nparam%s\nWrite-Host \"ACTION=[$Action]\"\n" % block,
            encoding="utf-8",
        )
        # The .bat's no-argument form, and its with-an-action form.
        for label, extra, want in (
            ("double-click (no args) binds the default", [], "ACTION=[Play]"),
            ("an explicit action binds", ["-Action", "Uninstall"], "ACTION=[Uninstall]"),
        ):
            r = subprocess.run([pwsh, "-NoProfile", "-File", str(stub)] + extra,
                               capture_output=True, text=True, timeout=120)
            out = (r.stdout or "") + (r.stderr or "")
            check(label, r.returncode == 0 and want in out,
                  want if r.returncode == 0 and want in out
                  else "rc=%d %s" % (r.returncode, out.strip().splitlines()[:1]))


# ---------------------------------------------------------------------------
# 6. install.ps1 parses, if there is a PowerShell to parse it with
# ---------------------------------------------------------------------------


def ps_syntax(pwsh, path):
    """(ok, detail) - PowerShell's own parser on a file, if there is one to run."""
    r = subprocess.run(
        [pwsh, "-NoProfile", "-Command",
         '$e=$null;$t=$null;'
         '[void][System.Management.Automation.Language.Parser]::ParseFile('
         '"%s",[ref]$t,[ref]$e);'
         'if($e.Count){$e|%%{"line $($_.Extent.StartLineNumber): $($_.Message)"}}'
         'else{"OK $($t.Count) tokens"}' % str(path).replace("'", "''")],
        capture_output=True, text=True, timeout=180,
    )
    out = (r.stdout or "").strip()
    ok = r.returncode == 0 and out.startswith("OK")
    return ok, (out.replace("\n", " | ")[:300] if r.returncode == 0 or out else "rc=%d" % r.returncode)


def check_ps_parse(pwsh):
    head("install.ps1 parses")
    if not pwsh:
        skip("install.ps1 has no syntax errors",
             "no PowerShell on this machine - get one from "
             "https://github.com/PowerShell/PowerShell/releases and set PWSH=")
        return
    ok, detail = ps_syntax(pwsh, INSTALL_PS1)
    check("install.ps1 has no syntax errors (%s)" % Path(pwsh).name, ok, detail)


# ---------------------------------------------------------------------------
# 7. The GUI: a window over install.ps1, not a second launcher
# ---------------------------------------------------------------------------

# Operations that belong to install.ps1 and only to install.ps1. The GUI must
# not contain any of them: a second downloader, hash, shortcut or recursive
# delete is exactly what this file is not allowed to be, and the uninstaller is
# the least-exercised code in the launcher - it has never run on Windows.
ENGINE_ONLY = (
    "Start-BitsTransfer", "DownloadFile", "WebClient", "Get-FileHash",
    "Invoke-WebRequest", "releases/download", "WScript.Shell",
    "Move-Item", "Remove-Item", "New-Shortcut", "isCheckout",
    "does not look like a game install folder",
)

# Reading state is not the same as doing the job. These are the only engine
# functions the GUI may call in-process, and only because they have no side
# effects; every action goes through the child process instead.
GUI_MAY_CALL = ("Get-Manifest", "Get-ManifestRepo", "Test-ManifestMatchesFile",
                "Get-RemoteManifest")


def strip_ps_comments(src):
    """Drop the leading <# #> block and whole-line # comments.

    Not a parser: trailing `# ...` comments are left in place. That is enough
    here because it only has to stop prose from satisfying - or failing - the
    checks below, and it fails safe (a missed match, which the checks report)
    rather than inventing one.
    """
    out = src
    if out.lstrip().startswith("<#"):
        end = out.find("#>")
        if end != -1:
            out = out[end + 2:]
    return "\n".join(l for l in out.splitlines() if not l.lstrip().startswith("#"))


def install_action_surface():
    """install.ps1's action names, and the function each one runs.

    Read out of the file rather than kept as a hand-written list, so adding an
    action to install.ps1 without giving the GUI a button - or the GUI a button
    for an action that does not exist - is a failure below.
    """
    src = read(INSTALL_PS1)
    vm = re.search(r"\[ValidateSet\(([^)]*)\)\]", src)
    actions = re.findall(r"'([A-Za-z]+)'", vm.group(1)) if vm else []
    sw = src.find("switch ($Action)")
    block = src[sw:] if sw != -1 else ""
    arms = {}
    for name in actions:
        m = re.search(r"'%s'\s*\{" % name, block)
        if not m:
            arms[name] = []
            continue
        end = len(block)
        for other in actions:
            if other == name:
                continue
            o = re.search(r"'%s'\s*\{" % other, block[m.end():])
            if o:
                end = min(end, m.end() + o.start())
        arms[name] = re.findall(r"\bInvoke-[A-Za-z]+\b", block[m.end():end])
    return actions, arms


def check_gui(m):
    head("launcher-gui.ps1")
    if not (GUI_PS1.is_file() and GUI_BAT.is_file()):
        check("the GUI exists", False, "windows/launcher-gui.ps1 or its .bat is missing")
        return
    raw = GUI_PS1.read_text(encoding="utf-8", errors="replace")
    code = strip_ps_comments(raw)
    engine = read(INSTALL_PS1)

    check("Set-StrictMode is on", "Set-StrictMode" in code)
    check("Stop on error", "$ErrorActionPreference = 'Stop'" in code)
    check("loads install.ps1 from beside itself",
          "Join-Path $PSScriptRoot 'install.ps1'" in code)

    # Regression guard. WinForms was once loaded *after* the install.ps1 load,
    # so the handler meant to report a missing install.ps1 could not itself show
    # a MessageBox, swallowed its own failure and exited with no window and no
    # message - the launcher just vanished. The assembly load must precede the
    # first statement that can fail.
    _add_type = code.find("Add-Type -AssemblyName System.Windows.Forms")
    _engine_load = code.find("Join-Path $PSScriptRoot 'install.ps1'")
    check("WinForms loads before anything that can fail, so errors can be shown",
          -1 < _add_type < _engine_load,
          "Add-Type at offset %d, install.ps1 load at offset %d" % (_add_type, _engine_load))

    # A WinForms Label has no Lines property - that is VB6/ASP.NET. Assigning one
    # is a hard stop under Set-StrictMode, and it killed the GUI on its first
    # statement. Multi-line control text goes in Text, joined with newlines.
    check("no VB6-style .Lines assignment on a control",
          not re.search(r"\$lbl\w*\.Lines\b", code),
          "WinForms controls have no Lines property")

    # --- the 1:1 contract: every action has a button, no button without one ---
    actions, arms = install_action_surface()
    launched = re.findall(r"Start-Engine\s+'([A-Za-z]+)'", code)
    check("every install.ps1 action has a GUI button, and vice versa",
          sorted(set(launched)) == sorted(set(actions)) and len(launched) == len(set(launched)),
          "GUI: %s / install.ps1: %s" % (sorted(set(launched)), sorted(set(actions))))
    for name in sorted(set(actions) & set(launched)):
        fns = arms.get(name) or []
        check("GUI action %r runs exactly one engine function" % name, len(fns) == 1,
              "%s -> %s" % (name, fns or "NOT FOUND in install.ps1's switch"))

    # --- it must not do the engine's job ---
    found = [t for t in ENGINE_ONLY if t in code]
    check("the GUI re-implements no engine operation", not found,
          "found: %s" % ", ".join(found) if found else
          "download, hash, move, delete, shortcut and the safety guard all stay in install.ps1")

    # A GUI-side function with an engine name is the same bug wearing a hat.
    engine_fns = set(re.findall(r"^function\s+([A-Za-z0-9-]+)", engine, re.M))
    shadows = [f for f in re.findall(r"^function\s+([A-Za-z0-9-]+)", code, re.M)
               if f in engine_fns]
    check("the GUI defines no function that install.ps1 already defines", not shadows,
          "shadowing: %s" % ", ".join(shadows) if shadows else
          "install.ps1's %d functions are never redefined" % len(engine_fns))

    called = {f for f in engine_fns if re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(f), code)}
    extra = sorted(called - set(GUI_MAY_CALL) - {"Invoke-Install"})
    check("the only engine functions the GUI calls in-process are the read-only ones",
          not extra, "unexpected: %s" % ", ".join(extra) if extra
          else "reads state with %s" % ", ".join(sorted(called & set(GUI_MAY_CALL))))

    # Invoke-Install is allowed in exactly one place: the headless self-check,
    # where $WhatIfOnly stops it before it downloads, writes or deletes. No
    # other action function may be called in-process at all - if the GUI can
    # reach one directly, the child process is no longer the only path to it.
    action_fns = sorted({f for fns in arms.values() for f in fns})
    self_at = code.find("CAD_GUI_HEADLESS")
    self_end = code.find("exit 0", self_at)
    selfcheck = code[self_at:self_end] if 0 <= self_at < self_end else ""
    stray = sorted({f for f in action_fns
                    for mm in re.finditer(r"(?<![\w-])%s(?![\w-])" % re.escape(f), code)
                    if not (self_at <= mm.start() < self_end)})
    check("no engine action is called in-process outside the -WhatIf self-check",
          bool(action_fns) and not stray and bool(selfcheck) and
          selfcheck.find("$WhatIfOnly = $true") != -1 and
          selfcheck.find("$WhatIfOnly = $true") < selfcheck.find("Invoke-Install"),
          "in-process, outside the self-check: %s" % ", ".join(stray) if stray else
          "%s reach the child process; Invoke-Install runs under -WhatIf only"
          % ", ".join(action_fns))

    # --- the progress bar reads the engine's own partial file ---
    check("progress is driven by the file install.ps1 downloads to",
          "cad-*.part" in code and "'cad-'" in engine and "'.part'" in engine,
          "cad-*.part in both - the GUI measures bytes, it does not fetch them")

    # --- no stale constants: everything comes from the manifest ---
    stale = []
    if re.search(r"\b[0-9a-f]{64}\b", code):
        stale.append("a pinned digest")
    if re.search(r"\bv\d+\.\d+", code):
        stale.append("a version literal")
    if re.search(r"CairnsAfterDark\.exe", code):
        stale.append("the asset name")
    if re.search(r"github\.com", code):
        stale.append("a release URL")
    check("no version, digest, asset or URL is hard-coded in the GUI", not stale,
          "hard-coded: %s" % ", ".join(stale) if stale else "reads manifest.json at run time")
    check("the digest on screen comes from the manifest",
          "$Manifest.sha256" in code and "[int64]$Manifest.size" in code)

    # --- the destructive action is confirmed, and cannot hang the window ---
    check("uninstall asks first",
          code.find("MessageBoxButtons]::YesNo") != -1 and
          code.find("MessageBoxButtons]::YesNo") < code.find("Start-Engine 'Uninstall'"),
          "the yes/no box is the GUI's; the delete and its guard are install.ps1's")
    check("the GUI never blocks on install.ps1's Read-Host prompt",
          "Read-Host" not in code and "Start-Engine 'Update' -Visible" in code,
          "update gets its own console window, because Read-Host needs one")

    check_gui_bat()
    check_gui_bundling()
    check_gui_readme()


def check_gui_bat():
    head("CairnsAfterDark-GUI.bat")
    raw = GUI_BAT.read_bytes()
    src = raw.decode("utf-8", errors="replace")
    # rem comments, dropped for the same reason PowerShell's are: prose must not
    # be able to satisfy - or fail - a check about what the file executes.
    code = "\n".join(l for l in src.splitlines()
                     if not re.match(r"\s*rem(\s|$)", l, re.I))

    check("is a .bat", src.startswith("@echo off"))
    check("uses CRLF line endings", b"\r\n" in raw and raw.count(b"\n") == raw.count(b"\r\n"),
          "cmd.exe is not required to cope with LF")
    check("finds launcher-gui.ps1 next to itself",
          'set "GUI=%~dp0launcher-gui.ps1"' in src)
    check("finds launcher-gui.ps1 in the bundle's launcher/ folder",
          "launcher\\launcher-gui.ps1" in src)
    # pwsh defaults to MTA; WinForms needs STA or the window can never appear.
    check("starts PowerShell with -STA", "-STA" in src,
          "PowerShell 7 defaults to MTA, where WinForms can fail outright")
    check("pauses when the GUI file is missing",
          "pause" in src and "exit /b 1" in src)
    check("falls back to pwsh when powershell.exe is absent", "where powershell" in src)

    # The same bug this launcher shipped once: an unbound argument. The GUI has
    # no -Action at all, so this only guards against one being introduced.
    check("the GUI .bat passes no -Action",
          "-Action" not in code, "install.ps1's own switch is reached through the GUI script")
    check("the GUI .bat is not the console entry point",
          '-File "%GUI%"' in code and "%~dp0install.ps1" not in code)


def check_gui_bundling():
    """A GUI that does not ship is a GUI that only works on the dev's machine."""
    head("the bundle ships the GUI")
    pack = read(WIN / "package-windows.sh")
    for src, dest in (("windows/launcher-gui.ps1", "$STAGE/launcher/"),
                      ("windows/CairnsAfterDark-GUI.bat", "$STAGE/")):
        pat = re.escape(src) + r"\s+\"\$STAGE(/launcher)?/\""
        check("package-windows.sh copies %s" % src,
              re.search(pat, pack) is not None,
              dest)
    check("the installer README.txt mentions the GUI",
          "CairnsAfterDark-GUI.bat" in pack,
          "and says the console path is the tested one")


def check_gui_readme():
    head("README: the GUI runbook")
    text = read(README)
    check("has a GUI runbook section",
          "## Runbook: the GUI" in text)
    runbook = text[text.find("## Runbook: the GUI"):]
    check("the GUI runbook is numbered",
          re.search(r"## Runbook: the GUI[\s\S]*?\n1\. \*\*", text) is not None)
    for key in ("CairnsAfterDark-GUI.bat", "progress", "Uninstall"):
        check("the GUI runbook covers %r" % key, key in runbook)
    # [\s\S] rather than [^\n] because the sentence wraps across a newline.
    check("says the GUI has never been run on Windows",
          re.search(r"never been (?:run|executed)[\s\S]{0,20}Windows", runbook) is not None,
          "the runbook opens by saying so")
    check("points at the headless self-check",
          "CAD_GUI_HEADLESS" in runbook)


def check_gui_parse(pwsh):
    head("launcher-gui.ps1 parses")
    if not pwsh:
        skip("launcher-gui.ps1 has no syntax errors",
             "no PowerShell on this machine - see the SKIP above")
        return
    ok, detail = ps_syntax(pwsh, GUI_PS1)
    check("launcher-gui.ps1 has no syntax errors (%s)" % Path(pwsh).name, ok, detail)


def check_gui_headless(pwsh, m):
    """Run the GUI's own launcher wiring, with no window and no Windows.

    CAD_GUI_HEADLESS=1 stops launcher-gui.ps1 after it has loaded install.ps1
    and proved Invoke-Install is reachable, which is the part that can be
    settled anywhere. It is not a claim that the window works.
    """
    head("launcher-gui.ps1 launcher wiring (headless)")
    if not pwsh:
        skip("launcher-gui.ps1 loads install.ps1 and reaches Invoke-Install",
             "no PowerShell on this machine - see the SKIP above")
        return
    env = dict(os.environ, CAD_GUI_HEADLESS="1")
    with tempfile.TemporaryDirectory() as td:
        # install.ps1 builds %APPDATA% paths at load time and Join-Path refuses
        # an empty one, so point them at scratch space.
        env["APPDATA"] = os.path.join(td, "appdata")
        env["USERPROFILE"] = os.path.join(td, "home")
        r = subprocess.run([pwsh, "-NoProfile", "-File", str(GUI_PS1)],
                           capture_output=True, text=True, timeout=180, env=env)
    out = (r.stdout or "") + (r.stderr or "")
    check("the GUI loads install.ps1 and stops at the self-check (%s)" % Path(pwsh).name,
          r.returncode == 0 and "SELFCHECK ok" in out,
          out.strip().splitlines()[-1][:200] if out.strip() else "rc=%d, no output" % r.returncode)
    if m:
        check("the GUI reads the digest the manifest pins", str(m.get("sha256")) in out,
              "the status pane cannot be showing a hard-coded digest")
    check("the self-check reached the real Invoke-Install, under -WhatIf",
          "Cairns After Dark - install" in out and "WhatIf: download skipped" in out,
          "printed by install.ps1 itself, so the GUI is wired to it")


# ---------------------------------------------------------------------------
# 8. export_presets.cfg: the preset the release is actually built from
# ---------------------------------------------------------------------------


def check_presets():
    head("export_presets.cfg")
    raw = PRESETS.read_text(encoding="utf-8")
    try:
        import tomllib
        data = tomllib.loads(raw)
        check("parses as TOML", True)
    except Exception as e:  # noqa: BLE001 - report whatever the parser said
        check("parses as TOML", False, str(e))
        return

    # Godot's ConfigFile understands `;` comments but NOT `#`. One `#` line
    # makes Godot silently report zero presets, so an export then fails with a
    # message that points nowhere near the cause.
    check("no '#' comments (Godot's ConfigFile cannot read them)",
          not re.search(r"^\s*#", raw, re.M))
    # Bare TOML keys cannot contain '/', and nearly every export option does.
    check("keys containing '/' are quoted",
          not re.search(r"^\s*[\w.-]+/[\w./-]*\s*=", raw, re.M))

    # `[preset.0]` is a nested table in TOML, not a flat key.
    presets = data.get("preset")
    if not check("has a [preset.*] table", isinstance(presets, dict) and bool(presets)):
        return
    check("has exactly one preset", len(presets) == 1, "%s" % sorted(presets))
    p = presets.get("0")
    if not check("preset.0 exists", p is not None):
        return
    name = p.get("name")
    check("preset has a name", bool(name))
    if not name:
        return
    check("preset name is 'Windows Desktop'", name == "Windows Desktop", name)

    # Every file that names the preset must name the one that exists.
    pack = read(WIN / "package-windows.sh")
    check("package-windows.sh exports this preset by name",
          ('PRESET="Windows Desktop"' in pack) or ('PRESET=%s' % name in pack))

    opts = p.get("options", {})
    check("platform is Windows Desktop", p.get("platform") == "Windows Desktop", str(p.get("platform")))
    check("runnable", p.get("runnable") is True)
    check("exports a .exe", str(p.get("export_path", "")).endswith(".exe"), str(p.get("export_path")))
    check("export_path is under the gitignored build/ dir",
          str(p.get("export_path", "")).startswith("build/"), str(p.get("export_path")))
    check("binary_format/architecture is x86_64", opts.get("binary_format/architecture") == "x86_64")
    check("binary_format/embed_pck is true (single self-contained file)",
          opts.get("binary_format/embed_pck") is True)
    check("exclude_filter keeps build/ out of its own export",
          "build/*" in str(p.get("exclude_filter", "")),
          str(p.get("exclude_filter")))

    # The export's product name should not drift from the project it exports.
    check("application/product_name matches the project name",
          opts.get("application/product_name") == "Cairns After Dark",
          str(opts.get("application/product_name")))


def check_readme():
    """The handoff has to exist, or "the installer works" gets reported again."""
    head("README")
    text = read(README)
    check("names this script as the thing to run",
          "Tools/verify_launcher.py" in text)
    check("has a numbered runbook for a human on Windows",
          "## Runbook: what a human must do on Windows" in text)
    check("the runbook covers install, uninstall and the destructive guard",
          all(k in text for k in ("Install from the bundle",
                                  "Confirm uninstall keeps saves",
                                  "Confirm the safety guard")))
    check("says plainly that nothing has been run on Windows",
          "has been executed on Windows" in text)


# ---------------------------------------------------------------------------
# 9. The Godot version the release is built with
# ---------------------------------------------------------------------------


def check_godot_pin():
    head("Godot version pin")
    pg = read(PROJECT)
    feats = re.search(r'config/features\s*=\s*PackedStringArray\("([^"]+)"', pg)
    check("project.godot declares the 4.3 feature set", feats is not None and feats.group(1) == "4.3",
          feats.group(1) if feats else "?")

    # package-windows.sh and the README must agree on which templates the
    # export needs, or a 1 GB download installs and the export still fails.
    pins = set()
    for src in (read(WIN / "package-windows.sh"), read(README)):
        pins |= set(re.findall(r"export_templates/(4\.[\w.]+)", src))
        pins |= set(re.findall(r"(4\.3-stable)", src))
    check("the export template version is pinned to 4.3",
          bool(pins) and all(p.startswith("4.3") for p in pins), str(sorted(pins)))

    godot = find_godot()
    if not godot:
        skip("local Godot is 4.3", "no godot on this machine (set GODOT=)")
        return
    r = subprocess.run([godot, "--version"], capture_output=True, text=True, timeout=120)
    ver = (r.stdout or "").strip()
    check("local Godot is 4.3 (GODOT=%s)" % godot, ver.startswith("4.3."), ver)

    # Templates live in a per-version dir named for the release, not for the
    # full `--version` banner: 4.3.stable.official.77dcf97d8 -> 4.3.stable.
    tpl_name = ver.split(".official")[0] or "4.3.stable"
    tpl = Path.home() / ".local/share/godot/export_templates" / tpl_name
    check("the %s Windows export template is installed" % tpl_name,
          (tpl / "windows_release_x86_64.exe").is_file(),
          "otherwise the export aborts; windows/README.md has the one-time step")


# ---------------------------------------------------------------------------
# 10. The published release is fetchable and is what the manifest pins
# ---------------------------------------------------------------------------


def fetch(url, want_bytes=None):
    req = urllib.request.Request(url, headers={"User-Agent": "CairnsAfterDark-verify_launcher"})
    if want_bytes:
        req.add_header("Range", "bytes=0-%d" % (want_bytes - 1))
    with urllib.request.urlopen(req, timeout=NET_TIMEOUT) as r:
        return r.read(), r


def check_release(m):
    head("published release (network)")
    if m is None or OFFLINE:
        skip("release asset exists and matches the pinned digest",
             "VERIFY_LAUNCHER_OFFLINE=1" if OFFLINE else "manifest unusable")
        return
    repo, tag, asset = m["repo"], m["tag"], m["asset"]
    base = "https://github.com/%s/releases/download/%s" % (repo, tag)

    # The payload is 181 MB. Proving the pin is right does not require moving
    # it: SHA256SUMS is a 188-byte release asset that has to agree with the
    # manifest, and the asset's own Content-Length has to be the manifest size.
    try:
        sums, _ = fetch(base + "/SHA256SUMS")
    except (urllib.error.URLError, OSError, ValueError) as e:
        skip("release asset exists and matches the pinned digest", "no network (%s)" % type(e).__name__)
        return

    published = {}
    for line in sums.decode("utf-8", "replace").splitlines():
        parts = line.split()
        if len(parts) == 2:
            published[parts[1]] = parts[0]
    check("published SHA256SUMS pins %s" % asset, asset in published,
          "release tag %s" % tag)
    check("published digest == windows/manifest.json digest",
          published.get(asset) == m["sha256"],
          "%s... / %s..." % (str(published.get(asset))[:16], m["sha256"][:16]))

    try:
        req = urllib.request.Request(base + "/" + asset, method="HEAD",
                                     headers={"User-Agent": "CairnsAfterDark-verify_launcher"})
        with urllib.request.urlopen(req, timeout=NET_TIMEOUT) as r:
            length = int(r.headers.get("Content-Length") or 0)
    except (urllib.error.URLError, OSError, ValueError) as e:
        skip("published asset size matches the manifest", "%s" % type(e).__name__)
        return
    check("published asset is downloadable", length > 0)
    check("published asset size == manifest size", length == m["size"],
          "%d / %d bytes" % (length, m["size"]))


# ---------------------------------------------------------------------------


def main():
    print("=" * 70)
    print(" verify_launcher - the Windows launcher's contract, checked off-Windows")
    print(" %s" % ROOT)
    print("=" * 70)

    check_files()
    check_referenced_paths()
    check_install_ps1()
    m = check_manifest()
    check_bat()
    pwsh = find_pwsh()
    check_ps_parse(pwsh)
    check_gui(m)
    if pwsh:
        check_gui_parse(pwsh)
        check_gui_headless(pwsh, m)
    else:
        skip("launcher-gui.ps1 has no syntax errors",
             "no PowerShell on this machine - see the SKIP above")
        skip("launcher-gui.ps1 loads install.ps1 and reaches Invoke-Install",
             "no PowerShell on this machine - see the SKIP above")
    if pwsh:
        check_bat_argv_with_pwsh(pwsh)
    else:
        skip("CairnsAfterDark.bat argument binding",
             "no PowerShell on this machine - see the SKIP above")
    check_presets()
    check_readme()
    check_godot_pin()
    check_release(m)

    print("\n" + "=" * 70)
    print(" %d passed, %d failed, %d skipped" % (passed, failed, skipped))
    if skipped:
        print(" skipped checks did not run. A skip is not a pass - see windows/README.md")
    print("=" * 70)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
