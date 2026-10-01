# Windows installer / distribution

Owns the path from "someone downloaded this" to "someone is playing the game".
Nothing in the player's install needs Godot, Git, Python, a compiler or the
source tree.

## What a new user does

1. Download **`CairnsAfterDark-Installer-0.1.0.zip`** (8 KB) from
   <https://github.com/maxta85/test-game/releases/tag/v0.1.0>.
2. Extract it anywhere, e.g. `C:\Games\CairnsAfterDark`.
3. Double-click **`CairnsAfterDark-GUI.bat`** for the window, or
   **`CairnsAfterDark.bat`** for the console. Both do exactly the same work.

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
| `CairnsAfterDark-GUI.bat` | the same four actions in a window, with a progress bar |

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
`.bat` is a three-line shim that runs `install.ps1`. The same argument settles
the GUI: WinForms is a few hundred KB of a runtime that is already there.

## The GUI

`launcher-gui.ps1` is a **window**, not a launcher. It contains no install, no
hash, no download, no shortcut and no delete of its own. Every button runs
`install.ps1 -Action <name>` in a child process, so the code that does the work
is the same code the console runs, and there is one implementation of the
destructive paths rather than two.

It adds the three things a console genuinely cannot do:

- **a real progress bar** for the 181 MB download, and the install log
  streaming into a window instead of a scrollback buffer,
- **state at a glance** — installed or not, which build is pinned, the first
  16 hex of the pinned digest, where the saves are — read from
  `manifest.json` and from `install.ps1`'s own `Get-Manifest`,
  `Test-ManifestMatchesFile` and `Get-RemoteManifest`,
- **a Saves Folder button**, because `%APPDATA%` is deliberately outside the
  install folder and a player will never find it otherwise.

Two design points worth knowing, because they look odd:

- **The download progress is the size of the file `install.ps1` is writing.**
  `install.ps1` streams the payload to `%TEMP%\cad-*.part` and only moves it
  into place once the digest matches, so the GUI polls that file's length. It
  is a measurement, not a second downloader. BITS can buffer before flushing,
  so the bar may sit at 0% and then jump.
- **The child process, not a dot-source.** `install.ps1` downloads with a
  blocking call and a WinForms window only repaints while its message loop
  runs, so calling it in-process would freeze the window solid for the whole
  fetch. Out of process the window stays live. The read-only helpers are still
  loaded in-process, because the status pane needs the pinned digest and the
  same hash comparison the installer uses.

`CAD_GUI_HEADLESS=1` runs the launcher's wiring and exits without opening a
window. That is what `Tools/verify_launcher.py` runs, and it is the only way
the GUI half has been executed at all:

```bash
CAD_GUI_HEADLESS=1 APPDATA=/tmp/fake USERPROFILE=/tmp/fake \
  pwsh -NoProfile -File windows/launcher-gui.ps1
```

## Files here

| File | Role |
|---|---|
| `CairnsAfterDark.bat` | console entry point; shim to `install.ps1` |
| `CairnsAfterDark-GUI.bat` | graphical entry point; shim to `launcher-gui.ps1` |
| `launcher-gui.ps1` | the window: buttons, state, progress, log. Calls `install.ps1`, replaces none of it |
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
- `launcher-gui.ps1` **parses with zero syntax errors** (2633 tokens,
  PowerShell 7.6.6), and its launcher wiring **runs for real** under
  `CAD_GUI_HEADLESS=1` on Linux: it loads `install.ps1` from beside itself,
  reads `manifest.json`, resolves the same digest, and reaches the real
  `Invoke-Install` under `-WhatIf` — which printed the installer's own plan and
  stopped before the download.
- The GUI's actions were checked to be exactly `install.ps1`'s `-Action` values,
  each of which dispatches to exactly one function in that file. The
  verifier also fails if the GUI ever gains a downloader, a hash, a shortcut, a
  recursive delete or its own copy of the "does this look like a game install
  folder" guard.
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
- That the GUI opens a window at all. `launcher-gui.ps1` has been parsed and
  its wiring run, and nothing about the window — controls, layout, the
  progress bar, the button handlers, the message boxes — has ever executed.
- Shortcut creation (COM `WScript.Shell`), Start-menu and desktop paths.
- BITS download and `WebClient` behaviour behind a real proxy, and whether
  `Start-BitsTransfer` is present on the player's SKU. This includes whether
  the GUI's progress bar moves smoothly, which depends on how BITS flushes.
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

## Runbook: the GUI

`launcher-gui.ps1`'s original grey layout ran once on Windows for 0.1.1 and
surfaced three real bugs (all fixed: a VB6-style `.Lines` assignment, a
MessageBox type loaded after the handler that needed it, and a startup note
claiming an install that did not exist). The dark banner layout shipped after
that **has never been run on Windows**, and neither has `install.ps1` — see
the section above. What *has* run is the file's launcher wiring, under
`CAD_GUI_HEADLESS=1`, on Linux with PowerShell 7.6.6: it loads
`install.ps1`, finds `manifest.json`, and reaches the real `Invoke-Install`
under `-WhatIf`. The headless check exits before the first control is
created, so no pixel of the new window has ever been drawn, and the console
`.bat` is unchanged and remains the tested path.

Do these in order. Steps 1–2 are cheap and catch most of what can be wrong;
3–8 are the ones that can lose data or a player's evening.

1. **The window opens at all.** Extract the bundle to e.g.
   `C:\Games\CairnsAfterDarkGUI` (a *different* folder from step 1 of the
   console runbook — two installs in one folder hides ordering bugs) and
   double-click `CairnsAfterDark-GUI.bat`. Expect: a dark window titled
   *Cairns After Dark* with a drawn banner (gradient, skyline silhouette,
   amber line — if the banner falls back to flat dark, that is the catch
   block doing its job, not a failure), a minimised console behind it, four
   lines of state in the banner, one large **PLAY** button over four small
   ones, and `Ready.` or an update note. *A window that never appears is
   the `-STA` apartment, a missing `launcher-gui.ps1`, or the pwsh-vs-Windows
   PowerShell split; check the minimised console for the error.*
2. **The state panel is right before you install anything.** It must read
   *Not installed yet*, `Pinned : 0.1.1 (v0.1.1)`, `Digest : ef6580420b6fd8ee…`
   (the first 16 hex of `manifest.json`, not a guess) and the `%APPDATA%` saves
   path. If it says *Installed* on a fresh folder, stop and find out why.
3. **Install, and watch the progress bar.** Press **PLAY** (it installs when
   nothing is installed) or **Repair**. The thin amber bar under the status
   line must advance and the log must fill with `install.ps1`'s own lines
   (`==> install: downloading…`, `==> verifying SHA-256`, `sha256 ok
   (ef6580420b6fd8ee…)`). Then *Done.*, and the state panel flips to
   *Installed … (sha256 verified)*. *This is the step the GUI exists for: if
   the bar sits at 0% and jumps at the end, that is the known BITS buffering
   behaviour, not a failure.*
4. **The console path still works after the GUI touched the folder.** Run
   `CairnsAfterDark.bat` and confirm it prints *already installed and verified*
   and skips the download. The two entry points must be interchangeable.
5. **Repair.** Append a byte to `CairnsAfterDark.exe`
   (`echo x >> CairnsAfterDark.exe`) and press **Repair**: the
   state panel must change to *Installed, but NOT the pinned build*, and
   pressing the button must re-download rather than trust the file. This is
   `Test-ManifestMatchesFile` doing its job, read from the GUI.
6. **Play.** Press **PLAY**. The game must start, and the window must come back
   to the front with *Done.* Buttons must be re-enabled afterwards; if they
   stay greyed, the engine's exit was never noticed.
7. **Uninstall, with the confirmation.** Press **Uninstall**, then *No* at the
   prompt — nothing may happen. Press it again and confirm *Yes*. The game and
   the shortcuts must go and `%APPDATA%\CairnsAfterDark` must still be there.
   *Then repeat the whole of console-runbook step 7 from this folder and from
   a git checkout: the "does this look like a game install folder" guard lives
   in `install.ps1` and the GUI must not be able to talk it out of firing.*
8. **Update.** Press it. With the network up it will report *You
   are up to date* (the remote manifest 404s — see gap 5 — so this is the
   expected result, not a bug). Then make the remote differ (point
   `manifest.json` at a newer tag on a branch) and press it again: the GUI must
   ask first, and *Yes* must open a second console window that asks again and
   is the one that downloads. *That double confirmation is deliberate: the
   GUI's box is consent, `install.ps1`'s `Read-Host` is the engine's, and a
   window-less child would hang forever waiting for an answer nobody can give.*
   *The background check must not pop a dialog — it only writes the status
   line. 0.1.1 popped a MessageBox for "could not reach GitHub" on every
   launch, which is why that behaviour is gone.*
9. **Saves** opens `%APPDATA%\CairnsAfterDark` in Explorer, and creates
   it if it is not there. **Close the window mid-download** (start a repair and
   hit the X): it must refuse to close.
10. **Only then** the polish: resize/DPI on a 4K screen, the minimised console
    still being there afterwards, and whether the two windows fight for focus.

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
5. **The update check cannot work for a player, because the release repo is
   PRIVATE.** This is the reported bug ("the launcher does not pick up GitHub
   updates"), and this section was previously wrong about why - it blamed
   `windows/` not having reached `main`, and said `Invoke-Update` reports *up
   to date*. Both wrong. Measured on 2026-09-30, from a clean machine,
   unauthenticated:

   ```
   curl -o /dev/null -w '%{http_code}\n' \
     https://raw.githubusercontent.com/maxta85/test-game/main/windows/manifest.json
   -> 404        (body: "404: Not Found")

   curl -o /dev/null -w '%{http_code}\n' \
     https://github.com/maxta85/test-game/releases/download/v0.1.1/CairnsAfterDark.exe
   -> 404

   curl https://api.github.com/repos/maxta85/test-game            -> 404 Not Found
   gh   api repos/maxta85/test-game                               -> "private": true
   ```

   `windows/manifest.json` **is** on `main` (authenticated fetch returns the
   0.1.1 manifest, 354 bytes). GitHub answers **404, not 403**, for a private
   repo, precisely so it does not confirm the repo exists - so a 404 here means
   "private or wrong path", never "not published yet". The launcher reported it
   as *could not reach GitHub*, which reads like being offline and sent the
   whole diagnosis the wrong way. It now says what actually happened.

   **The fix for a player is not in this folder: make the release publicly
   reachable** (public repo, or publish the release somewhere public). Until
   then, an installed copy can never update, and neither can a new one install.

   For machines that *do* have access, `install.ps1` reads `GITHUB_TOKEN` (or
   `GH_TOKEN`) from the environment - never from a file, because these files
   ship inside the release zip. That makes the manifest fetch work, and the
   payload download too, via the releases API: a private repo's
   `/releases/download/` path 404s *even with a token* (measured with
   `Authorization: token`, with `Bearer`, and anonymous), so
   `Get-ReleaseAssetUrl` resolves the asset id and follows the API's 302 to a
   signed `release-assets.githubusercontent.com` URL. Digest verification is
   unchanged and still happens before anything is installed.

6. **The update check was also broken on PowerShell 7 for any repo.** The
   fetch ended in `$req.Close()`, and `HttpWebRequest.Close()` exists in .NET
   Framework only - on PowerShell 7 (.NET Core) it threw
   `MethodNotFoundException` inside a `finally`, which the surrounding
   `catch { return $null }` turned into "no update", even against a *public*
   URL. Reproduced on pwsh 7.4.6. This repo supports PowerShell 7 deliberately
   (see the `pwsh.exe` handling and the `-STA` in `CairnsAfterDark-GUI.bat`),
   so that was a real hole. Disposing the *response* is what returns the
   connection; the request object does not need closing.

7. **The version comparison was string inequality.** "Any difference means an
   update exists" offered a 0.1.1 player 0.1.0 as an update, and a 0.1.9 player
   0.1.1. It is now `Get-UpdateVerdict`, which orders the versions numerically
   and returns `update` / `current` / `ahead` - a remote *older* than the
   install is reported as such instead of being offered. `launcher-gui.ps1`
   calls it rather than carrying its own comparison, which is how the two had
   drifted apart in the first place.

8. **`build/` is gitignored**, so the release artefacts (`CairnsAfterDark.exe`,
   the installer zip, `RELEASE-NOTES.md`) exist only on whichever machine ran
   `windows/package-windows.sh`. The published release is the copy that counts.

