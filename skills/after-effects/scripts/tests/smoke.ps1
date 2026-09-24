# smoke.ps1 - Windows runner smoke test. No After Effects required.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tests\smoke.ps1
#
# Uses tests\mock-afterfx.cmd as a stub engine, so the cases are deterministic
# and independent of whether the user happens to have AE open. Covers argument
# plumbing, the -s "$.evalFile(...)" payload, and the runner's error exit codes.
#
# Not covered here (needs a real AE install):
#   * exit code 2 - two AE versions installed, none chosen yet
#   * exit code 3 - "AE running without a listener" (skipped automatically when
#     a live listener is detected, since that condition cannot be reproduced)

$ErrorActionPreference = "Continue"

$testsDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptsDir = Split-Path -Parent $testsDir
$runner     = Join-Path $scriptsDir "runner.ps1"
$mock       = Join-Path $testsDir "mock-afterfx.cmd"
$someScript = Join-Path $scriptsDir "active-state.jsx"
$tmp        = [System.IO.Path]::GetTempPath()
$runnerOut  = Join-Path $tmp "ae-assistant-runner-out.txt"
$heartbeat  = Join-Path $tmp "ae-assistant-listener.json"

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0

function Invoke-Runner {
    param([string[]]$ArgList, [string]$Mode = "ok")
    $env:MOCK_AE_MODE = $Mode
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner @ArgList 2>&1 | Out-String
    return @{ Output = $output.Trim(); Code = $LASTEXITCODE }
}

function Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        Write-Host ("  PASS  " + $Name) -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host ("  FAIL  " + $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ("        " + $Detail) }
        $script:Fail++
    }
}

function Assert-Contains {
    param([string]$Name, [string]$Haystack, [string]$Needle)
    Assert $Name ($Haystack.Contains($Needle)) ("expected to find: " + $Needle + "`n        got: " + $Haystack)
}

function Get-ListenerAge {
    if (-not (Test-Path -LiteralPath $heartbeat)) { return $null }
    try { return ((Get-Date) - (Get-Item -LiteralPath $heartbeat).LastWriteTime).TotalSeconds } catch { return $null }
}

Write-Host "runner smoke test" -ForegroundColor Cyan
Write-Host ("  runner: " + $runner)
Write-Host ("  stub:   " + $mock)
Write-Host ""

# --- 1. args round-trip through the stub -----------------------------------
Write-Host "1. offline mode + argument round-trip"
$argsFile = Join-Path $tmp "smoke-args.json"
[System.IO.File]::WriteAllText($argsFile, '{"compName":"Main Comp","dryRun":true}', (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Runner @("-Mode", "offline", "-AfterFxPath", $mock, "-Timeout", "20", "-ArgsFile", $argsFile, $someScript)
Assert "exit code 0" ($r.Code -eq 0) ("exit=" + $r.Code + " output=" + $r.Output)
Assert-Contains "args reach the result" $r.Output '"compName":"Main Comp"'

# --- 2. the execution payload handed to the engine -------------------------
Write-Host "2. execution payload (-s + `$.evalFile)"
$raw = if (Test-Path -LiteralPath $runnerOut) { [System.IO.File]::ReadAllText($runnerOut) } else { "" }
Assert-Contains "uses -s with `$.evalFile" $raw '-s "$.evalFile('
Assert-Contains "forward-slash script path" $raw "active-state.jsx');"

# --- 3. no result file -----------------------------------------------------
Write-Host "3. stub produces no result"
$r = Invoke-Runner @("-Mode", "offline", "-AfterFxPath", $mock, "-Timeout", "8", $someScript) "noresult"
Assert "exit code 1" ($r.Code -eq 1) ("exit=" + $r.Code)
Assert-Contains "explains the failure" $r.Output "without producing a result file"

# --- 4. missing script -----------------------------------------------------
Write-Host "4. missing script"
$r = Invoke-Runner @("-Mode", "offline", "-AfterFxPath", $mock, "does-not-exist.jsx")
Assert "exit code 1" ($r.Code -eq 1) ("exit=" + $r.Code)
Assert-Contains "reports missing script" $r.Output "Script not found"

# --- 5. bad engine path ----------------------------------------------------
Write-Host "5. bad AfterFX path"
$r = Invoke-Runner @("-Mode", "offline", "-AfterFxPath", "C:\no\such\afterfx.exe", $someScript)
Assert "exit code 1" ($r.Code -eq 1) ("exit=" + $r.Code)
Assert-Contains "reports missing executable" $r.Output "AfterFX executable not found"

# --- 6. missing args file --------------------------------------------------
Write-Host "6. missing -ArgsFile"
$r = Invoke-Runner @("-Mode", "offline", "-AfterFxPath", $mock, "-ArgsFile", "nope.json", $someScript)
Assert "exit code 1" ($r.Code -eq 1) ("exit=" + $r.Code)
Assert-Contains "reports missing args file" $r.Output "Args file not found"

# --- 7. listener requested but absent --------------------------------------
Write-Host "7. forced listener with no listener"
$age = Get-ListenerAge
if ($null -ne $age -and $age -le 15) {
    Write-Host ("  SKIP  a live ae-listener.jsx is running (heartbeat " + [math]::Round($age, 1) + "s old)") -ForegroundColor Yellow
    $script:Skip++
} else {
    $r = Invoke-Runner @("-Mode", "listener", "-AfterFxPath", $mock, $someScript)
    Assert "exit code 3" ($r.Code -eq 3) ("exit=" + $r.Code)
    Assert-Contains "tells the user how to fix it" $r.Output "ae-listener.jsx"
}

Write-Host ""
$total = $script:Pass + $script:Fail
if ($script:Fail -eq 0) {
    Write-Host ("all $($script:Pass) checks passed" + $(if ($script:Skip -gt 0) { " ($($script:Skip) skipped)" } else { "" })) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("$($script:Fail) of $total checks failed") -ForegroundColor Red
    exit 1
}
