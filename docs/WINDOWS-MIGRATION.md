# Windows migration notes

This branch (`windows-support`) adds a Windows runner to the `after-effects`
skill. macOS support is unchanged — no macOS code path was modified, so the
existing behaviour is preserved bit-for-bit.

## 1. What was added

| File | Purpose |
|---|---|
| `skills/after-effects/scripts/runner.ps1` | Windows runner: AE detection, execution, result plumbing (`runner.sh` equivalent) |
| `skills/after-effects/scripts/ae-run.cmd` | Thin cmd wrapper so callers can use short commands |
| `skills/after-effects/scripts/ae-listener.jsx` | In-AE listener that lets the runner drive a **running** After Effects instance |
| `skills/after-effects/scripts/tests/smoke.ps1` | Mock-based smoke test for the runner (no AE required) |
| `skills/after-effects/scripts/tests/mock-afterfx.cmd` | Stub engine used by the smoke test |
| `skills/after-effects/scripts/lib/utils.jsx` | Now resolves the IPC temp dir per platform (`Folder.temp` on Windows, unchanged `/tmp` on macOS) |
| `skills/after-effects/SKILL.md` | Platform dispatch, Windows modes, `-ArgsFile` guidance |
| `README.md` | Requirements/Setup updated for Windows |

Scripts under `scripts/*.jsx` are cross-platform ExtendScript and were **not**
rewritten; only the platform-specific path handling in `lib/utils.jsx`,
`purge-cache.jsx` (Windows media-cache locations) and a default path in
`text-export-import.jsx` changed, plus documentation comments.

## 2. Platform findings (measured, not assumed)

All measurements below were taken on this machine:
**Windows, Adobe After Effects 26.2.1x2**, 2026-09-24.

### 2.1 After Effects on Windows is strictly single-instance

| Situation | Command | Observed |
|---|---|---|
| AE already running | `AfterFX.exe -r "script.jsx"` | exits in ~0.5 s, **no execution, no forwarding** |
| AE already running | `AfterFX.exe -s "<code>"` | exits in **0.14 s**, **no execution** |
| No AE running | `AfterFX.exe -r "script.jsx"` | exits after 8–63 s, **no execution** (see 2.2) |
| No AE running | `AfterFX.exe -s "<inline code>"` | **works** (~8 s cold start) |
| No AE running | `AfterFX.exe -s "$.evalFile('C:/.../active-state.jsx');"` | **works** (~8 s), `#include "lib/..."` resolves correctly |

Evidence that the script truly did not run in the failing cases: a probe script
containing `$.sleep(20000)` finished in 8 s (a real run takes 20 s longer), and
no result file was produced. UXP logs show no new engine session either.

**Consequence:** there is no command-line way to reach a running AE instance on
Windows. Any automation must either use an engine instance of its own (only
possible while no AE is running) or live inside the running AE.

### 2.2 `-r <file>` does not execute the file on this build

`AfterFX.exe -r <file.jsx>` silently no-ops (both with backslash and
forward-slash paths, and with or without a running instance). The runner
therefore executes scripts with:

```
AfterFX.exe -s "$.evalFile('<forward-slash-path>');"
```

This was verified end-to-end: `active-state.jsx` (which `#include`s
`lib/json2.jsx` and `lib/utils.jsx`) returned real data —
`{"aeVersion":"26.2.1x2","activeComp":null,...}`.

### 2.3 The IPC temp directory agrees across both sides

`Folder.temp` inside AE resolves to the same directory as
`[System.IO.Path]::GetTempPath()` in PowerShell (`%TEMP%`), which is what
`lib/utils.jsx` writes to and `runner.ps1` reads from. Verified by writing
`%TEMP%\s-test.txt` from inside AE and finding it on disk.

Note: the *strings* differ — ExtendScript reports the 8.3 short form while
PowerShell reports the long form:

```
AE (Folder.temp.fsName) : C:\Users\PEGION~1\AppData\Local\Temp
PowerShell (GetTempPath) : C:\Users\PegionFish\AppData\Local\Temp
```

Same directory, so the handshake works. Never compare these paths by string
equality — resolve them first if a comparison is ever needed.

### 2.4 Script file-write permission

`Pref_SCRIPTING_FILE_NETWORK_SECURITY = "1"` (i.e. *Allow Scripts to Write
Files and Access Network* is enabled), which is the AE 26 default. Scripts can
write to `%TEMP%` and read/write files without extra setup.

## 3. Architecture

```
                       ┌──────────────────────────────────────────┐
  no AE running ──────►│ offline mode: hidden AE engine instance  │
                       │ AfterFX.exe -s "$.evalFile('script')"    │
                       │ ~8 s per call, empty project             │
                       └──────────────────────────────────────────┘
  ae-run.cmd  ──► runner.ps1 ──┤
                       ┌──────────────────────────────────────────┐
  AE running with      │ listener mode: command dir + heartbeat   │
  ae-listener.jsx ────►│ %TEMP%\ae-assistant-commands\command.json│
                       │ executed inside the live AE session      │
                       └──────────────────────────────────────────┘
  AE running without
  a listener ────────►  exit code 3 (nothing executed)
```

Shared files (all in `%TEMP%`, agreed with `lib/utils.jsx`):

| File | Direction | Contents |
|---|---|---|
| `ae-assistant-args.json` | runner → AE | script arguments |
| `ae-assistant-result.json` | AE → runner | `writeResult()` output (+ `_nonce` in listener mode) |
| `ae-assistant-error.txt` | AE → runner | script-level failure |
| `ae-assistant-commands/command.json` | runner → listener | `{"nonce","script"}` |
| `ae-assistant-listener.json` | listener → runner | heartbeat, refreshed every ~2 s |
| `ae-assistant-runner-out.txt` / `-err.txt` | AE → runner | raw engine stdout/stderr (offline mode) |

Logs: `%USERPROFILE%\.ae-assistant-log` (runner), `~/.ae-assistant-extendscript.log` (ExtendScript).

## 4. Usage

```powershell
# detect AE version / cache the choice (exit 2 asks the user to pick)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\runner.ps1 -Background scripts\active-state.jsx

# arguments (Windows: use a file, cmd.exe eats JSON quotes)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\runner.ps1 -ArgsFile "$env:TEMP\ae-args.json" scripts\project-overview.jsx

# enable live-session mode (inside AE, once per session)
#   File > Scripts > Run Script File...  ->  scripts\ae-listener.jsx
```

To make listener mode permanent, copy `ae-listener.jsx` into AE's startup folder
so it loads automatically on every launch:

```powershell
$startup = Join-Path $env:APPDATA "Adobe\After Effects\<version>\Scripts\Startup"
Copy-Item skills\after-effects\scripts\ae-listener.jsx $startup
```

```cmd
:: equivalent, no PowerShell needed
copy skills\after-effects\scripts\ae-listener.jsx "%APPDATA%\Adobe\After Effects\26.2\Scripts\Startup\"
```

When loaded from `Startup` the listener stays silent; loaded by hand it shows a
one-line confirmation dialog.

Exit codes: `0` success, `1` execution error, `2` AE version choice required,
`3` AE busy (running without a listener).

## 5. Verification status

Everything below was executed on this machine unless marked otherwise.

| Check | Status |
|---|---|
| Runner logic: args round-trip, payload format, 4 error paths — `scripts\tests\smoke.ps1` (12 checks) | ✅ verified |
| AE detection (Program Files scan, caching, multi-version prompt) | ✅ verified against AE 26.2 |
| Offline mode: `-s "$.evalFile(...)"` executes a real skill script incl. `#include` chain | ✅ verified (~8 s, returned `aeVersion 26.2.1x2`) |
| `Folder.temp` == `%TEMP%` across AE and runner | ✅ verified |
| Listener mode end-to-end against a live AE session | ✅ verified (0.66 s round-trip, nonce-matched) |
| Listener mode argument plumbing (`-ArgsFile` → `readArgs()` → live project query) | ✅ verified |
| `-ArgsFile` with escaped quotes / non-ASCII payloads | ✅ verified |
| macOS runner untouched (`runner.sh` unchanged) | ✅ (no diff) |
| Offline mode against a saved project file | ⚠️ not run — a fresh engine has an empty project; scripts must call `app.open()` for file-based work |
| Exit code 2 (two AE versions installed) | ⚠️ not reachable on this machine (single install) |

Run the smoke test any time after changing the runner:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tests\smoke.ps1
```

## 6. Known limitations

- **Offline mode sees an empty project.** It starts a fresh engine, so
  `app.project.activeItem` is null. Open a project explicitly in the script
  (`app.open(new File(...))`) for file-based automation.
- **One AE instance at a time.** Offline mode is unavailable while the user has
  AE open; listener mode is unavailable if the user has not loaded the listener.
- **`-r` is unreliable on this build.** The skill uses `-s` + `$.evalFile()`
  everywhere; do not "simplify" it back to `-r`.
- **Cold start cost.** Each offline call pays ~8 s of AE engine startup.
- **Listener lifetime.** `app.scheduleTask` callbacks live in the AE session;
  loading the listener again after an AE restart is required (or install it into
  `Scripts\Startup\`).
