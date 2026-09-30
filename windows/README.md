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
| `../export_presets.cfg` | the export preset (repo root) |
| `../build/package-windows.sh` | builds, checksums, bundles, publishes |

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
./build/package-windows.sh --tag=v0.1.0     # tests -> export -> checksum -> bundle -> verify
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
*not* the same dialect.

Check it parses:

```bash
python3 -c "import tomli; tomli.load(open('export_presets.cfg','rb')); print('preset parses')"
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

**Verified on this machine (Linux, headless):**

- `export_presets.cfg` parses as TOML with a real parser, and Godot reads the
  same file (both facts proven, not assumed).
- The export succeeds and emits a single self-contained 181 MB `.exe` with no
  sidecar `.pck`.
- The exe is a valid **PE32+ x86-64** image; the embedded PCK has a matching
  `GDPC` magic at both ends and starts exactly at the template boundary.
- The embedded PCK was **extracted and booted headless**: it builds the same
  world and race the source tree does (359 junctions, 401 edges, 31 694 m,
  131 buildings, 46 CBD towers, Mulgrave Road Circuit), exit 0. Source and
  pack produce byte-identical log output (389 identical dummy-renderer
  warnings, which come from headless having no GPU — not from packaging).
- All 7 car models are real `glTF` binaries (139 MB) in the worktree while the
  git blob is a 133-byte LFS pointer; the pack carries 100.7 MB of imported car
  geometry.
- The published assets were **downloaded back from GitHub** and re-verified:
  both checksums match and the downloaded payload passes the same structural
  check.
- `install.ps1` **parses with zero syntax errors** and 24/24 behavioural checks
  pass under PowerShell 7.6.6, including the trust boundary: a single flipped
  byte, a truncated payload and a missing file are all rejected, and
  `Invoke-Update -Quiet` stays silent instead of throwing when the remote is
  unreachable.

To re-run the launcher tests (needs PowerShell; grab the tarball from
<https://github.com/PowerShell/PowerShell/releases> and untar it):

```bash
build/pwsh/pwsh -NoProfile -File build/test-launcher.ps1
```

**Not verified — cannot be, on Linux:**

- That the `.exe` renders and runs on Windows. Never executed.
- Shortcut creation (COM `WScript.Shell`), Start-menu and desktop paths.
- BITS download and `Invoke-WebRequest` behaviour behind a real proxy.
- The uninstaller's actual recursive delete and shortcut removal.
- The download path end-to-end on Windows (the URL pattern, the 302 to
  `release-assets.githubusercontent.com`, and the `Expand-Archive` step are
  reasoned, not run).
- Windows Defender / SmartScreen behaviour.

The first Windows run should be treated as a smoke test of the launcher, not
just the game.

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
5. **Uncommitted.** `windows/`, `export_presets.cfg` and `build/` are not
   committed here, so the update check's remote manifest does not resolve on
   `main` yet (verified: it degrades safely). The tag `v0.1.0` points at
   `main`'s HEAD, which does **not** contain these files. Someone owning the
   merge needs to commit them; until then the released installer works, but
   the in-app update check will never find a newer build.
