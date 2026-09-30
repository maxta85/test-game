# Windows installer / distribution

Owns the path from "someone downloaded this" to "someone is playing the game".
Nothing in the player's install needs Godot, Git, Python, a compiler or the
source tree.

## What a new user does

1. Download **`CairnsAfterDark-Installer-0.1.0.zip`** (8 KB) from
   <https://github.com/maxta85/test-game/releases/tag/v0.1.0>.
2. Extract it anywhere, e.g. `C:\Games\CairnsAfterDark`.
3. Double-click **`CairnsAfterDark.bat`**.

That is the whole install. The launcher then:

- downloads `CairnsAfterDark.exe` (~181 MB) from the release,
- **verifies its SHA-256 against the digest pinned in `launcher/manifest.json`
  before executing anything**, and refuses the download on mismatch,
- creates Start-menu and desktop shortcuts, and writes `version.txt` and
  `uninstall.bat` next to the game,
- records install state in `%APPDATA%\CairnsAfterDark\installed.json`.

Re-running the `.bat` is always safe: if the payload is already present and
its hash matches, the download is skipped entirely. A hand-deleted or
tampered-with binary is detected and re-fetched.

**None of this has ever been run on Windows.** The only things anyone has done
so far are on Linux, and they are listed in
[What is verified, and what is not](#what-is-verified-and-what-is-not) below.
The steps that need a person with a Windows box are in
[Runbook](#runbook-what-a-human-must-do-on-windows).

Actions:

| Command | What it does |
|---|---|
| `CairnsAfterDark.bat` | install if needed, then play (plus a silent update check) |
| `CairnsAfterDark.bat Install` | install / repair only |
| `CairnsAfterDark.bat Update` | offer a newer release |
| `CairnsAfterDark.bat Uninstall` | remove game + shortcuts, **keep saves** |

`CairnsAfterDark.exe` can also just be run directly — it is a single
self-contained file with the game data embedded (no sidecar `.pck`).

## Saves

`%APPDATA%\CairnsAfterDark`

Deliberately **outside** the install directory. An update overwrites the
install folder; a player who reinstalls to a different drive or folder gets a
clean install. Saves survive both, and survive uninstall.

## Why PowerShell and not Tauri/Electron

The whole job is download + hash + move files + write a `.lnk`. PowerShell
ships on every supported Windows and does all of it natively with no runtime
dependency. An Electron shell would add ~180 MB and a Node runtime to do the
same job with a larger supply chain. A `.bat` alone cannot show progress, ask
a yes/no question, or hash a file without shelling out to `certutil`, so the
`.bat` is a three-line shim that runs `install.ps1`.

## Files here

| File | Role |
|---|---|
| `CairnsAfterDark.bat` | entry point; shim to `install.ps1` |
| `install.ps1` | install / play / update / uninstall |
| `manifest.json` | **pinned** version + SHA-256; generated, not hand-edited |
| `package-windows.sh` | builds, checksums, bundles and publishes a release |
| `../export_presets.cfg` | the export preset (repo root) |
| `../Tools/verify_launcher.py` | checks everything below, on any machine, no Windows |

`manifest.json` pins an exact tag and digest on purpose. The launcher never
auto-follows "latest": a launcher that silently installs whatever is newest is
how players end up on an untested build. A new release means a deliberate
manifest bump, which is also the upgrade trigger.

## Building a release

One-time, per machine — **export templates**. Godot 4.3 has **no**
`--install-export-templates` flag; passing it silently boots the project
instead of installing anything. Install them by hand:

```bash
curl -L -o /tmp/tpl.tpz \
  https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_export_templates.tpz
mkdir -p ~/.local/share/godot/export_templates/4.3.stable
cd ~/.local/share/godot/export_templates/4.3.stable
unzip -q /tmp/tpl.tpz && mv templates/* . && rmdir templates
# -> windows_release_x86_64.exe must now exist there
```

Then, from the repo root:

```bash
./windows/package-windows.sh --tag=v0.1.0   # tests -> export -> checksum -> bundle -> verify
gh release create v0.1.0 --target main \
  build/CairnsAfterDark.exe \
  build/CairnsAfterDark-Installer-0.1.0.zip \
  build/SHA256SUMS --notes-file build/RELEASE-NOTES.md
```

`SKIP_TESTS=1` skips the test gate, `SKIP_EXPORT=1` reuses the existing
artefact. The script fails if the export produces a stray `.pck` (which would
mean `embed_pck` silently stopped working) and structurally verifies the
resulting PE before you can publish a broken build.

### export_presets.cfg is valid TOML *and* readable by Godot

Worth knowing before you edit it, because both facts are load-bearing:

- **Godot's ConfigFile only accepts `;` comments, not `#`.** A single `#`
  comment line makes Godot fail to load the file and report *zero* presets.
- **TOML bare keys cannot contain `/`,** and nearly every Godot export option
  is named like `binary_format/embed_pck`. Those keys are therefore quoted.

So the file uses `#`-free, fully quoted keys: valid for `tomli` and for Godot.
There is nowhere to put explanatory comments in it, which is why this README
exists. Note that `project.godot` uses `;` comments, so the two files are
*not* the same dialect. Both facts are asserted by `Tools/verify_launcher.py`,
because getting either one wrong fails the export with a message that points
nowhere near the cause.

Check it parses:

```bash
python3 -c "import tomllib; tomllib.load(open('export_presets.cfg','rb')); print('preset parses')"
```

## The car models are Git LFS objects

`assets/cars/*.glb` (~139 MB, 7 models) are LFS-tracked, and **GitHub's
"Download ZIP" does not run the LFS smudge filter** — a zip of this repo
yields 133-byte text pointers, and no cars load.

The release is therefore built from an export of a real checkout, never from
a zip or from git blobs. `package-windows.sh` asserts this on every build: the
payload must be a PE with a valid embedded PCK magic pair and a payload over
50 MB. A build assembled from LFS pointers would be about 1 MB. The shipped
`CairnsAfterDark.exe` embeds a 101 MB PCK carrying the imported geometry for
all 7 models.

Do not "simplify" the release by zipping the repo.

## First-launch seam

The game has no main menu yet — it boots straight into the world — and the
launcher does not depend on one. When the UI agent lands a splash/menu, there
is exactly one place to change: `Invoke-Play` in `install.ps1`, marked
`SEAM:` in the source. Pass the menu arguments there and let the game hand
control back. Nothing else in the launcher moves — no new install step, no new
dependency, no change to the update or uninstall paths.

## What is verified, and what is not

**The one command that checks the launcher, on any machine, with no Windows:**

```bash
python3 Tools/verify_launcher.py
```

It is stdlib-only, so it needs nothing installed. It asserts the launcher's
contract rather than its prose: that the manifest is well-formed and agrees
with `project.godot` and with the constants in `install.ps1`; that the preset
in `export_presets.cfg` is the one `package-windows.sh` actually exports;
that the export template version matches the project's `4.3` feature set; that
every path these files point at is committed to the repo rather than merely
present on one machine; that `install.ps1` parses; and that the `.bat`'s
no-argument double-click binds `-Action` (see the bug below). With a network
it also fetches the release's `SHA256SUMS` and proves the published digest is
the digest `install.ps1` pins. It degrades to a printed `SKIP`, never to a
silent pass, when PowerShell or the network is absent.

**Verified on this machine (Linux, headless):**

- `export_presets.cfg` parses as TOML with a real parser, and Godot reads the
  same file (both facts proven, not assumed: a fresh
  `--export-release "Windows Desktop"` run resolved the preset and produced a
  190 079 888-byte PE x86-64 with a 101 MB embedded PCK).
- The export emits a single self-contained `.exe` with no sidecar `.pck`.
- The exe is a valid **PE32+ x86-64** image; the embedded PCK has a matching
  `GDPC` magic at both ends.
- The embedded PCK was **extracted and booted headless**: it builds the same
  world and race the source tree does, exit 0.
- All 7 car models are real `glTF` binaries (139 MB) in the worktree while the
  git blob is a 133-byte LFS pointer; the pack carries 100.7 MB of imported car
  geometry.
- The published `CairnsAfterDark.exe` was **downloaded back from GitHub** and
  re-hashed: it is byte-identical to the digest in `windows/manifest.json`
  (`636ebd59…`, 190 079 456 bytes).
- `install.ps1` **parses with zero syntax errors** (2187 tokens, PowerShell
  7.6.6) and 24/24 behavioural checks pass, including the trust boundary: a
  single flipped byte, a truncated payload and a missing file are all rejected,
  and `Invoke-Update -Quiet` stays silent instead of throwing when the remote
  is unreachable.
- Godot 4.3 is the version everything is pinned to, end to end:
  `project.godot` declares the `4.3` feature set, the local editor is
  `4.3.stable.official.77dcf97d8`, and the `4.3.stable` Windows export
  template is installed.

### The bug this README exists for

`CairnsAfterDark.bat` shipped with

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Action %*
```

With no arguments — **the normal double-click** — `%*` expands to nothing, so
the command line ends in a bare `-Action`. PowerShell then fails to bind it:

```
Missing an argument for parameter 'Action'. Specify a parameter of type
'System.String' and try again.
```

exit code 1, nothing installed, game never starts. Reproduced with PowerShell
7.6.6 against `install.ps1`'s own `param()` block. It is fixed by branching on
`if "%~1"==""` and passing no `-Action` at all, letting the default `Play`
apply, and `Tools/verify_launcher.py` fails if that guard is ever removed.

**Not verified — cannot be, on Linux:**

- That the `.exe` runs at all on Windows. Never executed, on any machine.
- Shortcut creation (COM `WScript.Shell`), Start-menu and desktop paths.
- BITS download and `WebClient` behaviour behind a real proxy, and whether
  `Start-BitsTransfer` is present on the player's SKU.
- The uninstaller's actual recursive delete and shortcut removal.
- The download path end-to-end on Windows: the URL pattern, the 302 to
  `release-assets.githubusercontent.com` and TLS 1.2 negotiation are reasoned
  from the format, not run.
- Windows Defender / SmartScreen behaviour.

The first Windows run should be treated as a smoke test of the launcher, not
just the game.

## Runbook: what a human must do on Windows

Nothing in this folder has been executed on Windows. This is the list, in
order, of what only a person with a Windows box and a GPU can settle. Do not
report "the installer works" until step 6 passes — everything above it can pass
on a machine with no graphics driver at all.

1. **Install from the bundle.** Download
   <https://github.com/maxta85/test-game/releases/tag/v0.1.0>, extract
   `CairnsAfterDark-Installer-0.1.0.zip` to e.g. `C:\Games\CairnsAfterDark`,
   double-click `CairnsAfterDark.bat`. Expect: the download, a SHA-256 line,
   and the game starting. *This is the step that was broken; confirm the
   no-argument double-click installs and plays.*
2. **Confirm the payload really was verified.** The console must print
   `sha256 ok (636ebd59fac58bf2...)` before the game starts. Then re-run the
   `.bat`: it must say *already installed and verified* and skip the download.
   Corrupt it deliberately (`echo x >> CairnsAfterDark.exe`) and re-run: it
   must re-download rather than launch.
3. **Confirm the game renders.** A black screen or a crash on start means the
   export is broken, not the launcher. Capture the error.
4. **Confirm the shortcuts.** Start menu → *Cairns After Dark* and
   *Uninstall Cairns After Dark*, plus the desktop shortcut. Launching from a
   shortcut must not flash a console window and must not hang on a prompt.
5. **Confirm saves go outside the install folder.** Play for a minute, quit,
   and check that `%APPDATA%\CairnsAfterDark` exists and the install folder has
   no save data in it.
6. **Confirm uninstall keeps saves.** Run `CairnsAfterDark.bat Uninstall`.
   The game, `version.txt`, `uninstall.bat` and all three shortcuts must go;
   `%APPDATA%\CairnsAfterDark` must still be there. Then run it a second time
   on the now-removed folder and confirm it errors rather than deleting
   anything.
7. **Confirm the safety guard.** From a *git checkout*, run
   `windows\CairnsAfterDark.bat Uninstall`. It must refuse and print
   *it does not look like a game install folder*. The working tree must be
   untouched. This is the one destructive path in the launcher; check it
   before anyone else does.
8. **Confirm update and offline behaviour.** With no network, double-click and
   confirm the game still starts and no error window appears. With network,
   run `CairnsAfterDark.bat Update` and confirm it reports up to date (it
   will, because the remote manifest does not resolve on `main` yet — see gap
   5 below).
9. **Only then** look at SmartScreen, the missing icon, and crash triage.

## Known gaps before this is genuinely shippable

1. **No code signing.** SmartScreen will warn on first run. A real product
   needs a code-signing certificate and `codesign/enable` in the preset.
2. **No icon.** `application/icon` is empty, so the exe keeps Godot's default
   and shortcuts inherit it. Also why `application/modify_resources` is
   `false`: `rcedit` is not available here (it is a Windows binary needing
   Wine), so resource modification would only emit a warning. On a Windows
   build machine, drop in an `.ico`, set `application/icon`, and flip
   `modify_resources` to `true`.
3. **No console/log output** in the release build, so a crash on a player's
   machine is hard to triage. Consider shipping a separate console-wrapper
   build.
4. **No first-run GPU/driver check** and no crash reporter.
5. **The update check cannot work until `windows/` reaches `main`.**
   `Get-RemoteManifest` reads
   `raw.githubusercontent.com/maxta85/test-game/main/windows/manifest.json`,
   and that URL currently 404s, so `Invoke-Update` always reports *up to date*.
   It degrades safely (verified), but the feature is inert. The installed
   build and its shortcuts work regardless. Verified live, not assumed:
   `curl -o /dev/null -w '%{http_code}'
   https://raw.githubusercontent.com/maxta85/test-game/main/windows/manifest.json`
   returns `404`.
6. **`build/` is gitignored**, so the release artefacts (`CairnsAfterDark.exe`,
   the installer zip, `RELEASE-NOTES.md`) exist only on whichever machine ran
   `windows/package-windows.sh`. The published release is the copy that counts.

