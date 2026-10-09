<#
runner.ps1 - Windows runner: execute an AE ExtendScript and return its result.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File runner.ps1 [-Background] <script.jsx> [args-json]

Flags:
  -Background   Query mode (parity with runner.sh on macOS; --background also works)
  -AfterFxPath  Override the AE executable path (also used by tests with a stub)
  -Timeout      Total wait budget in seconds (default 180)
  -ArgsFile     Path to a JSON file with script arguments. Preferred over the
                positional args-json on Windows: write the JSON with your file
                tool, then pass -ArgsFile, avoiding shell quote-escaping issues.
  -Mode         auto (default) | offline | listener

Windows platform notes (measured on AE 26.2, 2026-09-24):
  * AE is strictly single-instance on Windows. When an AE instance is already
    running, `AfterFX.exe -r` and `AfterFX.exe -s` both exit silently in ~0.1s
    WITHOUT executing anything and WITHOUT forwarding to the running instance.
  * With no AE running, `AfterFX.exe -s "<code>"` starts a hidden AE engine,
    runs the code (measured ~8s cold start) and exits. ExtendScript file writes
    require Preferences > Scripting & Expressions > "Allow Scripts to Write
    Files and Access Network" (enabled by default in AE 26).
  * Because `-r <file>` does not run the file on this platform, this runner
    executes scripts through `-s "$.evalFile('<forward-slash-path>');"`.
    Relative `#include "lib/..."` still resolves against the script's own
    directory (verified).
  * To drive an AE instance that is ALREADY running (interactive use, i.e. the
    user's open project), load ae-listener.jsx inside that AE via
    File > Scripts > Run Script File... and this runner will talk to it through
    the command directory. See ae-listener.jsx for details.

Exit codes: 0 ok, 1 execution error, 2 AE version choice required, 3 AE busy
#>
[CmdletBinding()]
param(
    [switch]$Background,
    [string]$AfterFxPath = "",
    [int]$Timeout = 180,
    [Parameter(Position = 0)][string]$ScriptPath = "",
    [Parameter(Position = 1)][string]$ArgsJson = "",
    [string]$ArgsFile = "",
    [ValidateSet("auto", "offline", "listener")]
    [string]$Mode = "auto"
)

$ErrorActionPreference = "Stop"

# Force UTF-8 on stdout: when output is redirected (piped to another process
# or captured by an agent), .NET encodes [Console]::Out with the OEM codepage
# (437 on en-US, 936 on zh-CN). Chinese layer/comp names in the result JSON
# then become '?' (CP437) or GBK bytes — unrecoverable loss either way. The
# result file written by lib/utils.jsx is UTF-8, so the pipe must be UTF-8 too.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

# --- Paths ---------------------------------------------------------------
# Both sides (this runner and lib/utils.jsx via Folder.temp) resolve the same
# per-user temp directory: [IO.Path]::GetTempPath() == %TEMP% == Folder.temp
$TMP_DIR          = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
$ARGS_FILE        = Join-Path $TMP_DIR "ae-assistant-args.json"
$RESULT_FILE      = Join-Path $TMP_DIR "ae-assistant-result.json"
$ERROR_FILE       = Join-Path $TMP_DIR "ae-assistant-error.txt"
$CMD_DIR          = Join-Path $TMP_DIR "ae-assistant-commands"
$CMD_FILE         = Join-Path $CMD_DIR "command.json"
$HEARTBEAT_FILE   = Join-Path $TMP_DIR "ae-assistant-listener.json"
$CONFIG_FILE      = Join-Path $HOME ".ae-assistant-config"
$LOG_FILE         = Join-Path $HOME ".ae-assistant-log"
$POLL_INTERVAL_MS = 250
$POST_EXIT_GRACE  = 3      # seconds to keep waiting for the result after the process exits
$HEARTBEAT_MAX_AGE = 15    # seconds; older heartbeat => listener considered dead

$script:ResultNonce = ""

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try { Add-Content -Path $LOG_FILE -Value "[$stamp] $Message" -Encoding UTF8 } catch {}
}

function Emit-Json {
    param([string]$Text)
    [Console]::Out.WriteLine($Text)
}

function Emit-Error-Json {
    param([string]$Message, [string]$Detail = "")
    $payload = @{ error = $Message }
    if ($Detail) { $payload.detail = $Detail }
    if ($ScriptPath) { $payload.script = $ScriptPath }
    Emit-Json ($payload | ConvertTo-Json -Compress -Depth 4)
}

# --- Validate inputs -----------------------------------------------------

if (-not $ScriptPath) {
    Emit-Error-Json "No script path provided"
    Write-Log "ERROR: No script path provided"
    exit 1
}

try {
    $ScriptPath = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop).Path
} catch {
    Emit-Error-Json "Script not found: $ScriptPath"
    Write-Log "ERROR: Script not found: $ScriptPath"
    exit 1
}

if ($ScriptPath.Contains("'")) {
    Emit-Error-Json "Script path must not contain a single quote: $ScriptPath"
    Write-Log "ERROR: unsupported script path: $ScriptPath"
    exit 1
}

# -ArgsFile is the Windows-friendly way to pass a JSON payload
if ($ArgsFile) {
    if (-not (Test-Path -LiteralPath $ArgsFile)) {
        Emit-Error-Json "Args file not found: $ArgsFile"
        Write-Log "ERROR: Args file not found: $ArgsFile"
        exit 1
    }
    $ArgsJson = [System.IO.File]::ReadAllText($ArgsFile, [System.Text.Encoding]::UTF8)
    $ArgsJson = $ArgsJson.TrimStart([char]0xFEFF).Trim()
}

Write-Log "RUN: $ScriptPath"
if ($ArgsJson) { Write-Log "ARGS: $ArgsJson" }
if ($Background) { Write-Log "MODE: background" }

# --- Write args ----------------------------------------------------------

if ($ArgsJson) {
    [System.IO.File]::WriteAllText($ARGS_FILE, $ArgsJson, (New-Object System.Text.UTF8Encoding($false)))
} else {
    [System.IO.File]::WriteAllText($ARGS_FILE, "{}", (New-Object System.Text.UTF8Encoding($false)))
}

# --- AE detection --------------------------------------------------------

function Get-CachedAeApp {
    if (Test-Path -LiteralPath $CONFIG_FILE) {
        $cached = (Get-Content -LiteralPath $CONFIG_FILE -Raw -ErrorAction SilentlyContinue)
        if ($cached) { return $cached.Trim() }
    }
    return ""
}

function Set-CachedAeApp {
    param([string]$Name)
    try { Set-Content -LiteralPath $CONFIG_FILE -Value $Name -Encoding UTF8 } catch {}
}

function Get-AeInstallations {
    $found = @()
    $roots = @(
        (Join-Path ${env:ProgramFiles} "Adobe"),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "Adobe" } else { $null })
    )
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "Adobe After Effects*" } |
                Sort-Object Name -Descending
        foreach ($dir in $dirs) {
            $exe = Join-Path $dir.FullName "Support Files\AfterFX.exe"
            if (Test-Path -LiteralPath $exe) {
                $found += [pscustomobject]@{ Name = $dir.Name; Exe = $exe }
            }
        }
    }
    if ($found.Count -eq 0) {
        foreach ($hive in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\AfterFX.exe")) {
            try {
                $exe = (Get-ItemProperty -Path $hive -ErrorAction Stop).'(default)'
                if ($exe -and (Test-Path -LiteralPath $exe)) {
                    $found += [pscustomobject]@{ Name = "AfterFX.exe"; Exe = $exe }
                }
            } catch {}
        }
    }
    return $found
}

function Resolve-AeExe {
    param([string]$CachedName)

    if ($AfterFxPath) {
        if (-not (Test-Path -LiteralPath $AfterFxPath)) {
            Emit-Error-Json "AfterFX executable not found: $AfterFxPath"
            Write-Log "ERROR: AfterFX executable not found: $AfterFxPath"
            exit 1
        }
        return (Resolve-Path -LiteralPath $AfterFxPath).Path
    }

    $installations = @(Get-AeInstallations)
    if ($installations.Count -eq 0) {
        Write-Log "ERROR: No AE installation found"
        Emit-Error-Json "No Adobe After Effects installation found under Program Files\Adobe"
        exit 1
    }

    if ($CachedName) {
        foreach ($inst in $installations) {
            if ($inst.Name -eq $CachedName -or $inst.Exe -eq $CachedName) { return $inst.Exe }
        }
        Write-Log "Cached AE app '$CachedName' no longer present; re-detecting"
    }

    if ($installations.Count -eq 1) {
        Set-CachedAeApp $installations[0].Name
        Write-Log "AUTO-DETECTED: $($installations[0].Name)"
        return $installations[0].Exe
    }

    Write-Log "MULTIPLE AE VERSIONS: $(($installations | ForEach-Object { $_.Name }) -join ', ')"
    [Console]::Error.WriteLine("Multiple After Effects versions found:")
    for ($i = 0; $i -lt $installations.Count; $i++) {
        [Console]::Error.WriteLine("  $($i + 1). $($installations[$i].Name)")
    }
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("Set your preferred version by running:")
    [Console]::Error.WriteLine("  Set-Content -Path `"$CONFIG_FILE`" -Value `"$($installations[0].Name)`"")
    exit 2
}

# --- Listener detection --------------------------------------------------

function Get-ListenerAge {
    if (-not (Test-Path -LiteralPath $HEARTBEAT_FILE)) { return $null }
    try {
        $beat = (Get-Item -LiteralPath $HEARTBEAT_FILE).LastWriteTime
        return ((Get-Date) - $beat).TotalSeconds
    } catch { return $null }
}

$aeProcs = @(Get-Process -Name "AfterFX" -ErrorAction SilentlyContinue)
$aeRunning = $aeProcs.Count -gt 0
$listenerAge = Get-ListenerAge
$listenerActive = ($null -ne $listenerAge) -and ($listenerAge -le $HEARTBEAT_MAX_AGE)

Write-Log ("AE_RUNNING: " + $aeRunning + " LISTENER_AGE: " + $(if ($null -eq $listenerAge) { "n/a" } else { [math]::Round($listenerAge, 1) }))

$effectiveMode = $Mode
if ($Mode -eq "auto") {
    if ($listenerActive) {
        $effectiveMode = "listener"
    } elseif ($aeRunning) {
        $effectiveMode = "blocked"
    } else {
        $effectiveMode = "offline"
    }
}

if ($effectiveMode -eq "listener" -and -not $listenerActive) {
    Write-Log "ERROR: listener mode requested but no live listener (age=$listenerAge)"
    Emit-Error-Json "No live ae-listener.jsx detected. Load it inside After Effects via File > Scripts > Run Script File..." "Listener heartbeat is stale or missing"
    exit 3
}

if ($effectiveMode -eq "blocked") {
    Write-Log "ERROR: AE is running and no ae-listener.jsx is active"
    $msg = "After Effects is running, but no ae-listener.jsx is active in it. " +
           "On Windows, AE is single-instance: a second AfterFX.exe call exits immediately " +
           "without running the script. Fix it by either (1) running ae-listener.jsx inside " +
           "After Effects (File > Scripts > Run Script File...), or (2) closing After Effects " +
           "and letting this runner use its own offline engine instance."
    Emit-Error-Json $msg "ae_listener_required"
    exit 3
}

$aeExe = Resolve-AeExe (Get-CachedAeApp)
Write-Log "AE_EXE: $aeExe"

# --- Clear previous result ----------------------------------------------

foreach ($f in @($RESULT_FILE, $ERROR_FILE)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

function Read-Result {
    param([string]$Path)
    try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } catch { return "" }
}

# --- Execution: listener (drives an already-running AE) ------------------

if ($effectiveMode -eq "listener") {
    Write-Log "LISTENER MODE: delegating to running AE"
    if (-not (Test-Path -LiteralPath $CMD_DIR)) {
        New-Item -ItemType Directory -Path $CMD_DIR -Force | Out-Null
    }
    $nonce = [guid]::NewGuid().ToString()
    $scriptForward = $ScriptPath.Replace('\', '/')
    # Two plain lines: "<nonce>`n<script path>". ae-listener.jsx parses this
    # with a line split instead of eval() — the command file lives in the
    # shared temp dir, writable by any local process.
    $cmdPayload = $nonce + "`n" + $scriptForward
    $tmpCmd = "$CMD_FILE.tmp"
    [System.IO.File]::WriteAllText($tmpCmd, $cmdPayload, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmpCmd -Destination $CMD_FILE -Force

    $deadline = (Get-Date).AddSeconds($Timeout)
    while ($true) {
        $age = Get-ListenerAge
        if (($null -eq $age) -or ($age -gt $HEARTBEAT_MAX_AGE)) {
            Write-Log "ERROR: listener heartbeat lost during execution"
            Emit-Error-Json "ae-listener.jsx stopped responding while running the script" "listener heartbeat lost"
            exit 3
        }
        if (Test-Path -LiteralPath $RESULT_FILE) {
            $raw = Read-Result $RESULT_FILE
            if ($raw -and $raw.Contains($nonce)) {
                Write-Log "RESULT (listener): $raw"
                Emit-Json $raw
                exit 0
            }
        }
        if (Test-Path -LiteralPath $ERROR_FILE) {
            $errMsg = Read-Result $ERROR_FILE
            Write-Log "EXTENDSCRIPT ERROR (listener): $errMsg"
            Emit-Json (@{ error = "ExtendScript error"; detail = $errMsg; script = $ScriptPath } | ConvertTo-Json -Compress -Depth 4)
            exit 1
        }
        if ((Get-Date) -ge $deadline) {
            Write-Log "ERROR: listener timed out after ${Timeout}s"
            Emit-Error-Json "Script timed out after $Timeout seconds (listener mode)"
            exit 1
        }
        Start-Sleep -Milliseconds $POLL_INTERVAL_MS
    }
}

# --- Execution: offline (own hidden AE engine instance) ------------------

Write-Log "OFFLINE MODE: starting hidden AE engine"

$outFile = Join-Path $TMP_DIR "ae-assistant-runner-out.txt"
$errFile = Join-Path $TMP_DIR "ae-assistant-runner-err.txt"
foreach ($f in @($outFile, $errFile)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

# `-r <file>` does not execute the file on Windows; run it through `-s` instead.
# Verified: `-s "$.evalFile('C:/path/script.jsx');"` runs the script and keeps
# relative #include resolution intact.
$scriptForward = $ScriptPath.Replace('\', '/')
$jsCode = '$.evalFile(' + [char]39 + $scriptForward + [char]39 + ');'

$proc = $null
try {
    $proc = Start-Process -FilePath $aeExe -ArgumentList @("-s", "`"$jsCode`"") -PassThru `
                          -RedirectStandardOutput $outFile -RedirectStandardError $errFile
} catch {
    Write-Log "ERROR: failed to start $aeExe : $_"
    Emit-Error-Json "Failed to start After Effects: $_"
    exit 1
}

Write-Log "PID: $($proc.Id)"
$startedAt = Get-Date
$deadline = $startedAt.AddSeconds($Timeout)
$exitSeenAt = $null
$timedOut = $false

while ($true) {
    if (Test-Path -LiteralPath $RESULT_FILE) { break }
    if (Test-Path -LiteralPath $ERROR_FILE) { break }

    if ($proc.HasExited) {
        if ($null -eq $exitSeenAt) { $exitSeenAt = Get-Date }
        if (((Get-Date) - $exitSeenAt).TotalSeconds -ge $POST_EXIT_GRACE) { break }
    }
    if ((Get-Date) -ge $deadline) { $timedOut = $true; break }
    Start-Sleep -Milliseconds $POLL_INTERVAL_MS
}

if ($timedOut) {
    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill() } catch {}
    }
    Write-Log "ERROR: offline run timed out after ${Timeout}s"
    Emit-Error-Json "Script timed out after $Timeout seconds"
    exit 1
}

# --- Read result ---------------------------------------------------------

$elapsed = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
Write-Log "OFFLINE ENGINE EXITED after ${elapsed}s"

# Read the engine's raw stdout/stderr as UTF-8 (Get-Content would guess ANSI)
$stdout = Read-Result $outFile
$stderr = Read-Result $errFile

if (Test-Path -LiteralPath $RESULT_FILE) {
    $result = Read-Result $RESULT_FILE
    Write-Log "RESULT: $result"
    Emit-Json $result
    exit 0
}

if (Test-Path -LiteralPath $ERROR_FILE) {
    $errorMsg = Read-Result $ERROR_FILE
    Write-Log "EXTENDSCRIPT ERROR: $errorMsg"
    Emit-Json (@{ error = "ExtendScript error"; detail = $errorMsg; script = $ScriptPath } | ConvertTo-Json -Compress -Depth 4)
    exit 1
}

if ($stdout -or $stderr) {
    $joined = ("$stdout`n$stderr").Trim()
    Write-Log "AE OUTPUT: $joined"
    Emit-Json (@{ error = "After Effects ran without producing a result file"; detail = $joined; script = $ScriptPath } | ConvertTo-Json -Compress -Depth 4)
    exit 1
}

Write-Log "ERROR: no result file and no captured output"
Emit-Error-Json ("Script did not produce a result file and no output was captured. " +
                 "Check that AE has 'Allow Scripts to Write Files and Access Network' enabled " +
                 "in Preferences > Scripting & Expressions.")
exit 1
