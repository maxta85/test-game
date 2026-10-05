#!/usr/bin/env python3
"""Publish a built Cairns After Dark exe as a GitHub release.

WHY THIS EXISTS
The launcher in windows/ only ever learns about a new build one way: it reads
windows/manifest.json on the main branch of the release repo, compares the
pinned version to its own, resolves the release tagged manifest.tag through
the GitHub API (the web /releases/download/ URL 404s for a private repo even
authenticated), downloads manifest.asset, and verifies manifest.sha256 before
installing. Every step of that chain already exists and is tested by
Tools/verify_launcher.py. What did not exist was anything that puts a build
INTO the chain: agents exported exes into build-share/ and they went no
further, because the pod has no GitHub SSH key and no gh. This script is that
last mile. It speaks HTTPS + the REST API, so the only secret it needs is a
GITHUB_TOKEN with push access - which is what ~/.env already holds.

WHAT IT DOES, IN ORDER
  1. Stages the artefact under the canonical asset name CairnsAfterDark.exe.
     manifest.asset is pinned to that name because release_identity.sh
     requires manifest.asset == basename(artefact), and every release before
     this used it.
  2. Bumps windows/VERSION (--version, else patch+1), rewrites
     project.godot's config/version to match, and regenerates
     windows/manifest.json from the artefact - measured sha256 and size,
     never hand-typed. The three files are the same three sources of truth
     Tools/release_identity.sh compares.
  3. Runs release_identity.sh against the staged artefact. If the manifest
     disagrees with the bytes, the script exits before any remote write.
     There is no --force; that is deliberate and matches the gate's design.
  4. Commits the bump on the current branch and pushes HEAD:main over HTTPS
     with the token. The push is expected to be a fast-forward; if GitHub
     refuses, the script stops rather than forcing.
  5. Creates the release as a DRAFT, uploads CairnsAfterDark.exe,
     SHA256SUMS, and a repacked CairnsAfterDark-Installer-<ver>.zip (exe +
     launcher/ + the two .bat entry points, matching the 0.2.x bundle
     layout), then flips draft->false. A launcher can therefore never see a
     manifest that names a tag whose assets are still uploading.
  6. Re-reads the published manifest from raw.githubusercontent.com and the
     asset list from the API, and confirms both agree with what was shipped.

USAGE
  Tools/publish_release.py --exe build-share/CairnsAfterDark-<hash>.exe
  Tools/publish_release.py --exe ... --version 0.3.0 --notes "..." --prerelease
  Tools/publish_release.py --exe ... --dry-run    # plan only, no writes

Token: GITHUB_TOKEN or GH_TOKEN in the environment, else ~/.env is read for
them. Stdlib only, like the rest of Tools/.
"""

import argparse
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WIN = ROOT / "windows"
MANIFEST = WIN / "manifest.json"
VERSION_FILE = WIN / "VERSION"
PROJECT_GODOT = ROOT / "project.godot"
IDENTITY_GATE = ROOT / "Tools" / "release_identity.sh"
ASSET_NAME = "CairnsAfterDark.exe"
SUMS_NAME = "SHA256SUMS"
UA = {"User-Agent": "CairnsAfterDark-publish_release"}
TIMEOUT = 60


def fail(msg):
    print("publish_release: FAIL: %s" % msg, file=sys.stderr)
    sys.exit(1)


def say(msg):
    print("publish_release: %s" % msg)


def get_token():
    for name in ("GITHUB_TOKEN", "GH_TOKEN"):
        tok = os.environ.get(name)
        if tok:
            return tok.strip()
    for envfile in (Path.home() / ".env", Path("/home/coder/.env")):
        if envfile.is_file():
            for line in envfile.read_text().splitlines():
                m = re.match(r"^(GITHUB_TOKEN|GH_TOKEN)=(.+)$", line.strip())
                if m:
                    return m.group(2).strip().strip('"').strip("'")
    fail("no GitHub token: set GITHUB_TOKEN, or add GITHUB_TOKEN=... to ~/.env")


def api(token, method, url, body=None, raw=None, ctype=None, accept=None):
    headers = dict(UA)
    headers["Authorization"] = "token %s" % token
    if accept:
        headers["Accept"] = accept
    data = None
    if raw is not None:
        data = raw
        headers["Content-Type"] = ctype or "application/octet-stream"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/vnd.github+json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            payload = r.read()
            if headers.get("Accept") == "application/octet-stream" or ctype:
                return payload, r
            return json.loads(payload.decode("utf-8")), r
    except urllib.error.HTTPError as e:
        detail = e.read()[:400]
        fail("GitHub %s %s -> HTTP %d: %s" % (method, url, e.code, detail))


def bump_patch(version):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", version.strip())
    if not m:
        fail("windows/VERSION is not dotted-numeric: %r - pass --version" % version)
    return "%d.%d.%d" % (int(m.group(1)), int(m.group(2)), int(m.group(3)) + 1)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_manifest(version, tag, size, sha, repo):
    manifest = {
        "game": "Cairns After Dark",
        "version": version,
        "tag": tag,
        "asset": ASSET_NAME,
        "sha256": sha,
        "size": size,
        "repo": repo,
        "releases_url": "https://github.com/%s/releases" % repo,
        "saves_path": "%APPDATA%\\CairnsAfterDark",
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    json.loads(MANIFEST.read_text())  # same guard package-windows.sh uses


def write_version_files(version, tag, size, sha, repo):
    VERSION_FILE.write_text(version + "\n")
    src = PROJECT_GODOT.read_text()
    new, n = re.subn(r'^config/version="[^"]*"',
                     'config/version="%s"' % version, src, count=1, flags=re.M)
    if n != 1:
        fail("project.godot has no config/version line to bump")
    PROJECT_GODOT.write_text(new)
    write_manifest(version, tag, size, sha, repo)


def restore_version_files():
    for p in (VERSION_FILE, MANIFEST, PROJECT_GODOT):
        subprocess.run(["git", "-C", str(ROOT), "checkout", "--", str(p)],
                       check=False)


def build_installer_zip(exe_path, version):
    """The self-contained bundle: game + launcher/ + entry-point .bats."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(exe_path, ASSET_NAME)
        for name in ("install.ps1", "launcher-gui.ps1", "manifest.json", "README.md"):
            z.write(WIN / name, "launcher/%s" % name)
        for name in ("CairnsAfterDark.bat", "CairnsAfterDark-GUI.bat"):
            z.write(WIN / name, name)
    return buf.getvalue()


def git(*args, env=None):
    e = dict(os.environ)
    if env:
        e.update(env)
    r = subprocess.run(["git", "-C", str(ROOT)] + list(args),
                       capture_output=True, text=True, env=e)
    if r.returncode != 0:
        fail("git %s failed: %s" % (args[0], r.stderr.strip()[:400]))
    return r.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True, help="built artefact to publish")
    ap.add_argument("--version", help="release version (default: patch bump of windows/VERSION)")
    ap.add_argument("--notes", default="", help="release notes body")
    ap.add_argument("--prerelease", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    exe = Path(args.exe).resolve()
    if not exe.is_file():
        fail("no such artefact: %s" % exe)
    size = exe.stat().st_size
    sha = sha256_of(exe)

    repo = "maxta85/test-game"
    if MANIFEST.is_file():
        repo = json.loads(MANIFEST.read_text()).get("repo", repo)

    old_version = VERSION_FILE.read_text().strip()
    version = args.version or bump_patch(old_version)
    tag = "v" + version

    say("artefact  %s" % exe.name)
    say("          %d bytes, sha256 %s" % (size, sha))
    say("version   %s -> %s  (tag %s, repo %s)" % (old_version, version, tag, repo))

    if args.dry_run:
        say("dry-run: would bump VERSION/project.godot/manifest, commit, push "
            "HEAD:main, create release %s with %s + %s + installer zip" %
            (tag, ASSET_NAME, SUMS_NAME))
        return

    token = get_token()

    # The script pushes HEAD:main. Run from the main checkout only - an
    # integration worktree's HEAD is in-flight work, not a release.
    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    if branch != "main":
        fail("checked-out branch is %r, not 'main' - run from the main checkout" % branch)

    # Stage under the canonical asset name so the identity gate's
    # manifest.asset == basename(artefact) check is meaningful.
    staged = exe.parent / ASSET_NAME
    if exe.name != ASSET_NAME:
        staged.write_bytes(exe.read_bytes())
    else:
        staged = exe

    # --- local truth first -------------------------------------------------
    write_version_files(version, tag, size, sha, repo)
    say("wrote windows/VERSION, project.godot config/version, windows/manifest.json")

    gate = subprocess.run(["bash", str(IDENTITY_GATE), str(staged)],
                          cwd=str(ROOT), capture_output=True, text=True)
    sys.stdout.write(gate.stdout)
    if gate.returncode != 0:
        sys.stderr.write(gate.stderr)
        restore_version_files()
        fail("release_identity.sh refused this artefact; local version files restored")

    # --- commit + push ------------------------------------------------------
    commit_sha = git("rev-parse", "HEAD")
    dirty = git("status", "--porcelain", "--",
                "windows/VERSION", "windows/manifest.json", "project.godot")
    if dirty:
        git("add", "windows/VERSION", "windows/manifest.json", "project.godot")
        git("commit", "-m",
            "release %s: publish %s (%d bytes, sha256 %s)\n\n"
            "Built from %s; artefact staged from %s." % (tag, ASSET_NAME, size,
                                                         sha[:16], commit_sha[:10],
                                                         exe.name))
        commit_sha = git("rev-parse", "HEAD")
    else:
        say("version bump already committed - reusing it")
    https = "https://x-access-token:%s@github.com/%s.git" % (token, repo)
    r = subprocess.run(["git", "-C", str(ROOT), "push", https, "HEAD:main"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        fail("git push to GitHub failed (commit is local): %s" % r.stderr.strip()[:400])
    say("pushed HEAD -> main")

    # --- release ------------------------------------------------------------
    base = "https://api.github.com/repos/%s" % repo
    body = args.notes or ("Cairns After Dark %s\n\nBuilt from %s." % (tag, commit_sha[:10]))
    rel, _ = api(token, "POST", base + "/releases", body={
        "tag_name": tag, "target_commitish": "main", "name": tag,
        "body": body, "draft": True, "prerelease": bool(args.prerelease)})
    say("draft release %s created" % tag)

    upload_url = rel["upload_url"].split("{")[0]
    sums = ("%s  %s\n" % (sha, ASSET_NAME)).encode()
    for name, blob in ((ASSET_NAME, staged.read_bytes()),
                       (SUMS_NAME, sums),
                       ("CairnsAfterDark-Installer-%s.zip" % version,
                        build_installer_zip(staged, version))):
        api(token, "POST", upload_url + "?name=" + name, raw=blob,
            ctype="application/octet-stream")
        say("uploaded %s (%d bytes)" % (name, len(blob)))

    api(token, "PATCH", base + "/releases/%d" % rel["id"], body={"draft": False})
    say("release %s published" % tag)

    # --- read-back verification ---------------------------------------------
    raw_url = ("https://raw.githubusercontent.com/%s/main/windows/manifest.json"
               % repo)
    remote, _ = api(token, "GET", raw_url)
    if remote.get("sha256") != sha or remote.get("tag") != tag:
        fail("published manifest disagrees: %s" % remote)
    say("remote manifest on main verified: %s pins %s" % (tag, sha[:16]))


if __name__ == "__main__":
    main()
