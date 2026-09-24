---
name: after-effects
description: >
  Automate Adobe After Effects via ExtendScript. Use when the user asks to
  create, modify, or query anything in an After Effects project — layers,
  keyframes, expressions, effects, compositions, assets, rendering, batch
  operations. Generates and executes JSX ExtendScript via osascript on macOS
  or via a PowerShell runner on Windows (hidden AE engine or in-AE listener).
compatibility: Requires Adobe After Effects installed. macOS uses the bash/JXA runner (runner.sh). Windows uses the PowerShell runner (runner.ps1, PowerShell 5.1+), which drives either a hidden AE engine instance or a live AE via ae-listener.jsx. Needs "Allow Scripts to Write Files and Access Network" enabled in AE Preferences > Scripting & Expressions.
allowed-tools: Bash(osascript *) Bash(chmod *) Bash(bash *) Bash(powershell *) Read Write
metadata:
  author: aedev-tools
  version: "1.1"
---

## Overview

This skill automates After Effects by generating ExtendScript (.jsx) and executing it through a platform runner. It reads project state through query scripts, uses rule files for domain knowledge, and wraps all mutations in undo groups.

## Platform dispatch (read first)

Pick the runner for the current OS. Everything else in this document is written once, using `$SKILL_RUN` as the placeholder for the platform command:

| OS | Runner | `$SKILL_RUN` |
|---|---|---|
| macOS | `scripts/runner.sh` (bash + osascript/JXA) | `bash "$SKILL_SCRIPTS/runner.sh"` |
| Windows | `scripts/runner.ps1` (PowerShell) | `powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_SCRIPTS\runner.ps1"` |

On Windows, `scripts\ae-run.cmd` wraps `runner.ps1`, so `ae-run.cmd -Background scripts\active-state.jsx` is equivalent to the long form.

### Windows execution modes (measured on AE 26.2, 2026-09-24)

After Effects on Windows is **strictly single-instance**. While an AE window is
open, a second `AfterFX.exe` call (with `-r` or `-s`) exits silently in ~0.1 s
**without running the script and without forwarding it**. The runner therefore
has two working modes and picks one automatically:

| Situation | Mode | Behaviour |
|---|---|---|
| No AE running | **offline** | Starts a hidden AE engine, runs the script (~8 s cold start), exits. The script sees an empty project — operate on project *files* (`app.open()`), not on a live session. |
| AE running **and** `ae-listener.jsx` loaded inside it | **listener** | Sends the script to the running AE. The script sees the user's open project, active comp and selection — like macOS. |
| AE running, no listener | **blocked** | Exit code 3 with instructions. Nothing runs. |

To enable **listener** mode, load `scripts/ae-listener.jsx` inside After Effects
once per session (File > Scripts > Run Script File...). For a permanent setup,
copy it to `%APPDATA%\Adobe\After Effects\<version>\Scripts\Startup\`.

Check which mode is available before promising a live-session operation:

```
ae-run.cmd scripts\active-state.jsx
```
- exit 0 → ran (offline or listener; the log line records which)
- exit 3 → blocked; tell the user to load the listener or close AE

**Windows: pass script arguments with `-ArgsFile`, not as a positional JSON string.** cmd.exe strips the double quotes inside JSON. Write the JSON with your file tool first:

```
Write  ->  %TEMP%\ae-args.json   (content: {"mode":"folder","folderName":"Images"})
run    ->  ae-run.cmd --background scripts\project-overview.jsx -ArgsFile %TEMP%\ae-args.json
```

On macOS the original positional form still works: `bash "$SKILL_SCRIPTS/runner.sh" --background scripts/project-overview.jsx '{"mode":"folder"}'`.

**The `bash scripts/runner.sh ...` examples below are macOS form.** On Windows,
run the same script through `runner.ps1` (or `ae-run.cmd`) instead, moving any
JSON arguments into an `-ArgsFile`. All scripts, args and result files are
identical across platforms.

## First-Time Setup

1. Run the runner with any query script to detect the AE version:
   - macOS: `bash scripts/runner.sh --background scripts/active-state.jsx`
   - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\runner.ps1 -Background scripts\active-state.jsx`
2. If multiple AE versions are installed, the user must choose one — the runner will prompt (exit code 2) and print the exact command that caches the choice.
   - Windows caches the choice in `%USERPROFILE%\.ae-assistant-config` (a `Set-Content` command is printed).
   - macOS caches it in `~/.ae-assistant-config`.
3. Ensure AE Preferences > Scripting & Expressions > "Allow Scripts to Write Files and Access Network" is enabled.
4. Windows only: to use the running AE session (rather than a hidden engine),
   load `scripts/ae-listener.jsx` inside After Effects.

## Workflow

For every user request:

### Step 1: Gather context (auto-run, no confirmation needed)

Use `--background` for all query scripts — this skips `ae.activate()` so AE doesn't steal focus:

```bash
bash scripts/runner.sh --background scripts/active-state.jsx
```
Then read `/tmp/ae-assistant-result.json` for active comp, selected layers, CTI.

If this is the first interaction or the project context is unknown, also run:
```bash
bash scripts/runner.sh --background scripts/project-overview.jsx
```
This returns a **summary** by default: folder tree with counts, all comps listed, footage grouped by file type. NOT every individual file.

To drill into a specific folder:
```bash
bash scripts/runner.sh --background scripts/project-overview.jsx '{"mode": "folder", "folderName": "Images"}'
```

Only use full mode when you actually need every item listed:
```bash
bash scripts/runner.sh --background scripts/project-overview.jsx '{"mode": "full"}'
```

### Step 2: Drill down if needed (auto-run)

If the task targets a specific comp:
```bash
bash scripts/runner.sh --background scripts/comp-detail.jsx '{"compName": "Comp Name"}'
```

If the task targets specific layers:
```bash
bash scripts/runner.sh --background scripts/layer-detail.jsx '{"layerNames": ["Layer 1", "Layer 2"]}'
```

Omit `compName` to use the active comp. Omit `layerNames` to use selected layers.

#### Additional query scripts

**Expression errors** — scan for broken expressions:
```bash
bash scripts/runner.sh --background scripts/expression-errors.jsx
bash scripts/runner.sh --background scripts/expression-errors.jsx '{"compName": "Main Comp"}'
```

**Font inventory** — list all fonts used across the project:
```bash
bash scripts/runner.sh --background scripts/font-inventory.jsx
```

**Project audit** — comprehensive health check (unused footage, missing files, expression errors, duplicate solids, font issues, empty folders):
```bash
bash scripts/runner.sh --background scripts/project-audit.jsx
bash scripts/runner.sh --background scripts/project-audit.jsx '{"checks": ["unused", "missing", "expressions"]}'
```

### Step 3: Load domain knowledge

Read the relevant rule file from `rules/`. Always read `rules/extendscript-fundamentals.md` — it contains ES3 constraints that apply to every generated script.

| Task involves | Load rule file |
|---|---|
| Layers (create, move, parent, duplicate) | [rules/layer-manipulation.md](rules/layer-manipulation.md) |
| Keyframes, animation, easing | [rules/keyframes-animation.md](rules/keyframes-animation.md) |
| Expressions | [rules/expressions.md](rules/expressions.md) |
| Compositions (create, precompose, nest) | [rules/composition-management.md](rules/composition-management.md) |
| Effects and parameters | [rules/effects.md](rules/effects.md) |
| Import, footage, assets | [rules/assets-footage.md](rules/assets-footage.md) |
| Render queue, export | [rules/rendering.md](rules/rendering.md) |
| Bulk/batch operations | [rules/batch-operations.md](rules/batch-operations.md) |
| Version-specific features | [references/ae-api-versions.md](references/ae-api-versions.md) |

### Step 4: Generate the action script

**CRITICAL: Resolve the skill's real path first**

Before writing or executing any action script, resolve the skill's real (non-symlinked) path. ExtendScript `#include` cannot follow symlinks, so you MUST use the real filesystem path.

Run this once at the start of each session.

macOS:
```bash
SKILL_SCRIPTS="$(readlink -f ~/.claude/skills/after-effects-assistant/scripts 2>/dev/null || readlink ~/.claude/skills/after-effects-assistant/scripts)"
echo "$SKILL_SCRIPTS"
```

Windows (PowerShell):
```powershell
$p = "$env:USERPROFILE\.claude\skills\after-effects-assistant\scripts"
$SKILL_SCRIPTS = (Get-Item -LiteralPath $p -Force).Target
if (-not $SKILL_SCRIPTS) { $SKILL_SCRIPTS = (Resolve-Path -LiteralPath $p).Path }
$SKILL_SCRIPTS
```

Use the resolved path (`$SKILL_SCRIPTS`) for all subsequent Write and runner commands in this session.

**Why this matters:**
- `~/.claude/skills/` is typically a symlink (or a junction on Windows) — ExtendScript `#include` fails through them
- Writing to the real `scripts/` directory lets `#include "lib/json2.jsx"` resolve correctly
- The resolved path changes per machine, so never hardcode it

Every generated script MUST follow this template:

```jsx
#include "lib/json2.jsx"
#include "lib/utils.jsx"

(function() {
    app.beginUndoGroup("AE Assistant: <action description>");
    try {
        var args = readArgs();
        var comp = getActiveComp();
        if (!comp) return;

        // ... action code ...

        writeResult({ success: true, message: "<what was done>" });
    } catch (e) {
        try { writeResult({ error: e.toString(), line: e.line, fileName: e.fileName }); }
        catch(e2) { writeError(e.toString(), "line:" + e.line); }
    } finally {
        app.endUndoGroup();
    }
})();
```

#### utils.jsx helpers available for generated scripts

| Function | Purpose |
|----------|---------|
| `writeResult(obj)` | Write JSON result to the system temp dir (`%TEMP%` on Windows, `/tmp` on macOS — see `AE_TMP_DIR` in `lib/utils.jsx`) |
| `writeError(msg, detail)` | Last-resort error capture when JSON.stringify fails |
| `readArgs()` | Read args from `ae-assistant-args.json` in the same temp dir |
| `getLayerType(layer)` | Returns type string: "shape", "text", "null", "precomp", etc. |
| `getBlendModeName(mode)` | BlendingMode enum → string name |
| `getActiveComp()` | Returns active comp or writes error and returns null |
| `getSelectedOrAllLayers(comp)` | Selected layers array, or all layers if none selected |
| `hexToRGB(hex)` | `"#ff0000"` → `[1, 0, 0]` |
| `getCompByName(name)` | Find comp in project items by name |
| `walkProperties(group, leafFn, path)` | Recursive property tree walker — calls `leafFn(prop, path)` on leaves |
| `bubbleSort(arr, compareFn)` | ES3-compatible in-place sort |
| `framesToSeconds(frames, comp)` | Frame count → seconds via `comp.frameDuration` |
| `appendLog(message)` | Append to `~/.ae-assistant-extendscript.log` |

**Write the script using the Write tool, then execute with a short runner command:**

1. Use the **Write** tool to write the script to `$SKILL_SCRIPTS/ae-action.jsx` (the resolved real path)
2. Execute it:
```bash
# macOS
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/ae-action.jsx"
```
```powershell
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_SCRIPTS\runner.ps1" "$SKILL_SCRIPTS\ae-action.jsx"
```

**IMPORTANT:** Do NOT inline the script through a shell heredoc (`cat > file << 'SCRIPT'` on macOS, multiple `echo >>` lines on Windows) — that puts the entire script in the command line, cluttering the permission prompt. Always use the Write tool for the script content, then a short runner command to run it.

### Step 5: Execute or confirm

**Auto-run** (no confirmation needed):
- All read-only queries (active-state, project-overview, comp-detail, layer-detail, expression-errors, font-inventory, project-audit)
- Non-destructive additions: adding a keyframe, adding an effect, creating a layer, creating a comp

**Confirm before running** (show the script and ask the user):
- Deleting layers or comps
- Removing keyframes
- Replacing footage
- Clearing expressions
- Render queue operations
- Project cleanup (removing unused items, consolidating solids)
- Any operation the user might not expect

### Built-in action scripts

Before generating a custom `ae-action.jsx`, check if a built-in script already handles the task. These are permanent, tested scripts with args-based behavior:

**Running these on Windows:** the examples below are written in macOS form (positional JSON args). On Windows, write the same JSON object to a file and pass it with `-ArgsFile` — cmd.exe strips the double quotes out of a positional JSON string:

```powershell
# Write {"compName": "Main Comp", "suffix": " COPY"} to %TEMP%\ae-args.json first,
# then:
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_SCRIPTS\runner.ps1" -ArgsFile "$env:TEMP\ae-args.json" "$SKILL_SCRIPTS\true-comp-duplicator.jsx"
```

**True Comp Duplicator** — deep-clone a comp with independent sub-comps (confirm before running):
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/true-comp-duplicator.jsx" '{"compName": "Main Comp", "suffix": " COPY"}'
```

**Font Replace** — find and replace fonts across the project. Always dryRun first:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/font-replace.jsx" '{"find": "Helvetica", "replace": "Inter-Regular", "dryRun": true}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/font-replace.jsx" '{"find": "Helvetica", "replace": "Inter-Regular"}'
```

**Project Cleanup** — remove unused footage, consolidate duplicate solids, remove empty folders. Always dryRun first:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/project-cleanup.jsx" '{"dryRun": true}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/project-cleanup.jsx"
```

**Batch Rename** — rename layers, comps, or project items in bulk:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/batch-rename.jsx" '{"target": "layers", "mode": "find-replace", "find": "Layer", "replace": "Element"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/batch-rename.jsx" '{"target": "layers", "mode": "prefix", "prefix": "BG_"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/batch-rename.jsx" '{"target": "layers", "mode": "sequence", "base": "Card", "start": 1}'
```

**Layer Stagger** — offset selected layers in time for cascade animations:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/layer-stagger.jsx" '{"offset": 0.1, "unit": "seconds", "direction": "forward"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/layer-stagger.jsx" '{"offset": 2, "unit": "frames"}'
```

**Expression Replace** — find/replace text in expressions project-wide. Always dryRun first:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/expression-replace.jsx" '{"find": "comp(\"Old\")", "replace": "comp(\"New\")", "dryRun": true}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/expression-replace.jsx" '{"find": "comp(\"Old\")", "replace": "comp(\"New\")"}'
```

**Organize Project** — auto-sort project panel items into folders by type:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/organize-project.jsx" '{"structure": "by-type"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/organize-project.jsx" '{"structure": "by-extension"}'
```

**Batch Comp Settings** — change fps, resolution, duration across multiple comps:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/batch-comp-settings.jsx" '{"scope": "all", "fps": 25}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/batch-comp-settings.jsx" '{"compNames": ["Comp 1", "Comp 2"], "width": 3840, "height": 2160}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/batch-comp-settings.jsx" '{"scope": "nested", "fps": 30, "duration": 10}'
```

**Easing Presets** — apply professional easing or bounce/elastic expressions:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/easing-presets.jsx" '{"preset": "smooth"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/easing-presets.jsx" '{"preset": "snappy"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/easing-presets.jsx" '{"preset": "bounce"}'
```

**Anchor Point Mover** — reposition anchor point with visual position compensation:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/anchor-point-mover.jsx" '{"position": "center"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/anchor-point-mover.jsx" '{"position": "bottom-left"}'
```

**Reverse Keyframes** — reverse animation on selected properties:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/reverse-keyframes.jsx"
```

**Select Layers** — select layers by type, label, attribute, or name:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/select-layers.jsx" '{"type": "text"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/select-layers.jsx" '{"hasExpressions": true}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/select-layers.jsx" '{"nameContains": "BG"}'
```

**Layer Sort** — reorder layers in timeline by name, position, in-point, type, or label:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/layer-sort.jsx" '{"sortBy": "name", "order": "ascending"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/layer-sort.jsx" '{"sortBy": "position-y"}'
```

**Smart Precompose** — precompose with auto-trimmed duration:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/smart-precompose.jsx" '{"name": "My Precomp", "trimToContent": true}'
```

**Copy Ease** — copy easing from one keyframe and paste to others:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/copy-ease.jsx" '{"mode": "both"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/copy-ease.jsx" '{"sourceLayer": "Logo", "sourceProperty": "Position", "sourceKeyIndex": 2}'
```

**Relink Footage** — batch-relink missing footage from search directories. Always dryRun first:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/relink-footage.jsx" '{"searchPaths": ["/Volumes/Projects/footage"], "dryRun": true}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/relink-footage.jsx" '{"searchPaths": ["/Volumes/Projects/footage"]}'
```

**SRT Import** — create timed subtitle text layers from an SRT file:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/srt-import.jsx" '{"srtPath": "/path/to/subs.srt", "fontSize": 48}'
```

**Text Export/Import** — export all text to CSV, edit externally, reimport:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/text-export-import.jsx" '{"mode": "export", "csvPath": "/tmp/text.csv"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/text-export-import.jsx" '{"mode": "import", "csvPath": "/tmp/text.csv"}'
```

**Batch Expression** — apply, remove, enable, or disable expressions in bulk:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/batch-expression.jsx" '{"property": "opacity", "expression": "wiggle(2, 10)", "mode": "apply"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/batch-expression.jsx" '{"mode": "remove"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/batch-expression.jsx" '{"mode": "disable"}'
```

**Randomize Properties** — apply random values to transform properties:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/randomize-properties.jsx" '{"property": "rotation", "min": -15, "max": 15}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/randomize-properties.jsx" '{"property": "position", "minX": 0, "maxX": 1920, "minY": 0, "maxY": 1080}'
```

**Un-PreCompose** — extract layers from a precomp back into parent (confirm before running):
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/un-precompose.jsx" '{"precompLayerName": "Precomp 1"}'
```

**Comp from CSV** — generate comp variations from spreadsheet data (confirm before running):
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/comp-from-csv.jsx" '{"templateComp": "Lower Third", "csvPath": "/path/data.csv"}'
```

**Render Queue Batch** — add multiple comps to render queue (confirm before running):
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/render-queue-batch.jsx" '{"compNames": ["Final_16x9", "Final_9x16"], "outputPath": "~/Desktop/renders/"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/render-queue-batch.jsx" '{"scope": "folder", "folderName": "Finals"}'
```

**Explode Shape Layer** — split shape groups into individual layers:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/explode-shape-layer.jsx" '{"layerName": "AI Import"}'
```

**Incremental Save** — save project with auto-incrementing version number:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/incremental-save.jsx" '{"comment": "before revisions"}'
```

**Purge Cache** — clear memory caches, disk cache, and free resources. dryRun to check size first:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/purge-cache.jsx" '{"dryRun": true}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/purge-cache.jsx"
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/purge-cache.jsx" '{"memory": true, "disk": false}'
```

**Trim Comp to Content** — trim/extend comp duration to exactly fit layer content:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/trim-comp-to-content.jsx"
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/trim-comp-to-content.jsx" '{"padding": 0.5}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/trim-comp-to-content.jsx" '{"recursive": true}'
```

**Null from Layers** — create a null at each selected layer's position, auto-parent:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/null-from-layers.jsx"
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/null-from-layers.jsx" '{"naming": "custom", "prefix": "Driver"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/null-from-layers.jsx" '{"position": "comp-center"}'
```

**Fit to Comp** — scale selected layers to fit/fill comp dimensions:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/fit-to-comp.jsx" '{"mode": "fit"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/fit-to-comp.jsx" '{"mode": "fill"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/fit-to-comp.jsx" '{"mode": "stretch"}'
```

**Label Layers** — batch-set label colors on layers by type, name, or selection:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/label-layers.jsx" '{"label": 3, "target": "selected"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/label-layers.jsx" '{"label": 1, "target": "text"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/label-layers.jsx" '{"label": 5, "target": "all", "nameContains": "BG"}'
```

**Blend Mode Set** — set blending mode on selected layers:
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/blend-mode-set.jsx" '{"mode": "SCREEN"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/blend-mode-set.jsx" '{"mode": "MULTIPLY"}'
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/blend-mode-set.jsx" '{"mode": "ADD"}'
```

**Split Layer** — split selected layers at CTI (confirm before running — modifies layer timing):
```bash
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/split-layer.jsx"
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/split-layer.jsx" '{"time": 2.5}'
```

### Step 6: Execute and read result

```bash
# macOS — execute the action script (already written to $SKILL_SCRIPTS/ae-action.jsx in Step 4)
bash "$SKILL_SCRIPTS/runner.sh" "$SKILL_SCRIPTS/ae-action.jsx" '{"arg1": "value1"}'
```
```powershell
# Windows — args go through a JSON file (see Platform dispatch)
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_SCRIPTS\runner.ps1" -ArgsFile "$env:TEMP\ae-args.json" "$SKILL_SCRIPTS\ae-action.jsx"
```

The runner prints the result JSON to stdout, and also leaves it in the system temp dir (`%TEMP%\ae-assistant-result.json` on Windows, `/tmp/ae-assistant-result.json` on macOS).

### Debugging failures

If a script fails, check these in order:
1. **Exit code 3 on Windows** — AE is running but no listener is loaded. Nothing
   was executed. Either load `scripts/ae-listener.jsx` inside AE
   (File > Scripts > Run Script File...) or close AE to use the offline engine.
2. **`~/.ae-assistant-log`** — the runner logs every execution, mode, args, results and errors here (both platforms)
3. **Runner error file** — `/tmp/ae-assistant-error.txt` (macOS, JXA-level errors) or `%TEMP%\ae-assistant-error.txt` (Windows, script-level errors)
4. **Runner output** — `%TEMP%\ae-assistant-runner-out.txt` / `-err.txt` on Windows: raw AfterFX.exe stdout/stderr
5. **`~/.ae-assistant-extendscript.log`** — ExtendScript-level logs from `appendLog()` in utils.jsx
6. **AE Preferences** — Ensure "Allow Scripts to Write Files and Access Network" is enabled

When an error occurs, read `~/.ae-assistant-log` to understand what happened, fix the script, and retry.

## MUST

- ALWAYS wrap mutations in `app.beginUndoGroup()` / `app.endUndoGroup()`
- ALWAYS use matchNames for property access, not display names (display names are localized)
- ALWAYS use 1-based indexing for layers and project items
- ALWAYS write action scripts to `$SKILL_SCRIPTS/ae-action.jsx` (the resolved real path, NOT a temp directory)
- ALWAYS use relative `#include "lib/json2.jsx"` and `#include "lib/utils.jsx"` (NOT absolute paths)
- ALWAYS wrap in an IIFE to avoid global scope pollution
- ALWAYS use `var`, never `let` or `const` (ES3)
- ALWAYS write results with `writeResult()` — it resolves the platform temp dir for you
- ALWAYS use `getActiveComp()` to get the active comp (handles the null/CompItem check and writes error)
- ALWAYS use the non-interactive flag for query scripts to avoid focus-steal (`--background` on macOS, `-Background` on Windows)

## FORBIDDEN

- NEVER use ES5+ syntax: let, const, arrow functions, template literals, destructuring
- NEVER use Array.map, Array.filter, Array.reduce, Array.forEach (not in ES3)
- NEVER use JSON.parse or JSON.stringify without including json2.jsx
- NEVER write action scripts to a temp directory — ExtendScript `#include` can't resolve `lib/` from there
- NEVER use absolute paths in `#include` — they break through symlinks/junctions
- NEVER hardcode layer indices — use names, selection, or iteration
- NEVER run destructive operations without user confirmation
- NEVER assume a comp is active without checking
- NEVER inline scripts through a shell heredoc (`cat > file << 'SCRIPT'` on macOS, chained `echo >>` on Windows) — use the Write tool instead, then a short runner command
