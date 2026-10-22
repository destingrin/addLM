<#
.SYNOPSIS
    Reconcile addLM's PREDICTED context size with the context the llama-server
    ACTUALLY loaded, and correct the OpenCode config if they differ.

.DESCRIPTION
    addLM computes a context size before launch with context-calc.py, which
    measures the model's memory footprint with llama-fit-params. That value is
    written into opencode.runtime.json -> opencode.json as `limit.context`.

    But the server has the final say: llama.cpp's --fit may settle on a
    different context, and the server is the only authority on what it actually
    loaded. llama-server exposes the truth on GET /props:

        default_generation_settings.n_ctx   <- the real per-slot context
        n_ctx_train                          <- the model's TRAINED window

    (/v1/models is NOT authoritative here: its `context_length` is the trained
    window, not the running one.)

    This helper waits for the server to come up, reads the real n_ctx, and:
      * rewrites opencode.runtime.json with the REAL value (so limit.context
        always matches the running server), and
      * regenerates opencode.json from it.

    The output budget is re-derived from the real context, because OpenCode's
    usable window is (context - output) and a budget that was sized for a
    larger context can make every step look like an overflow.

.PARAMETER Port
    Port the llama-server is listening on (default 8081).

.PARAMETER Requested
    The context size addLM asked for. Recorded in the outcome file so a
    mismatch is visible.

.PARAMETER Output
    The output budget addLM computed for the requested context.

.PARAMETER ScriptDir
    Folder holding opencode.runtime.json and context-sync's outcome file.

.PARAMETER FixModels
    Full path to fix-models.py, which regenerates opencode.json.

.PARAMETER TimeoutSec
    How long to wait for the server to become ready. Model loading on a big
    quant can take a while, so this is generous by default.

.NOTES
    Writes its outcome to <ScriptDir>\opencode.runtime.actual.json.
    Exits 0 on success (server reached), 1 if the server never became ready.
#>
param(
    [int]$Port = 8081,
    [int]$Requested = 0,
    [int]$Output = 2048,
    [string]$ScriptDir,
    [string]$FixModels,
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = 'Continue'

$runtimePath = Join-Path $ScriptDir 'opencode.runtime.json'
$outcomePath = Join-Path $ScriptDir 'opencode.runtime.actual.json'

# UTF-8 WITHOUT a BOM. Windows PowerShell 5.1's Set-Content -Encoding UTF8
# writes a BOM, which makes Python's json.loads() fail with
# "Unexpected UTF-8 BOM" and silently fall back to the default limits.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-JsonFile {
    param([string]$Path, [hashtable]$Data)
    $json = $Data | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($Path, $json, $Utf8NoBom)
}

# The output budget tiering, identical to the one in addLM.ps1, applied to the
# REAL context instead of the requested one. Kept as a function so both files
# cannot drift apart.
function Get-OutputBudget {
    param([int]$Ctx)
    if ($Ctx -le 0) { return 2048 }
    $b = 2048
    if ($Ctx -le 8192) { $b = 1024 }
    elseif ($Ctx -le 16384) { $b = 1536 }
    # Never let the output allowance eat more than half the real window:
    # OpenCode's usable window is (context - output).
    if ($b -gt [int]($Ctx / 2)) { $b = [int]($Ctx / 2) }
    if ($b -lt 256) { $b = 256 }
    return $b
}

# ---------------------------------------------------------------- wait for server
$baseUrl = "http://127.0.0.1:$Port"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$actual = 0
$source = ''
$trained = 0

while ((Get-Date) -lt $deadline) {
    try {
        $props = Invoke-RestMethod -Uri "$baseUrl/props" -TimeoutSec 5 -ErrorAction Stop

        # Authoritative: the per-slot context the server actually loaded.
        if ($props.default_generation_settings -and $props.default_generation_settings.n_ctx) {
            $actual = [int]$props.default_generation_settings.n_ctx
            $source = 'props.default_generation_settings.n_ctx'
        }
        if (-not $actual -and $props.n_ctx) {
            $actual = [int]$props.n_ctx
            $source = 'props.n_ctx'
        }
        # Fallback: /slots[0].n_ctx
        if (-not $actual) {
            try {
                $slots = Invoke-RestMethod -Uri "$baseUrl/slots" -TimeoutSec 5 -ErrorAction Stop
                if ($slots -and $slots.Count -gt 0 -and $slots[0].n_ctx) {
                    $actual = [int]$slots[0].n_ctx
                    $source = 'slots[0].n_ctx'
                }
            } catch { }
        }
        if ($props.n_ctx_train) { $trained = [int]$props.n_ctx_train }

        # Some llama.cpp builds (b11756) do not expose n_ctx_train on /props.
        # /v1/models carries it under meta.n_ctx_train. It is informational
        # only - it never influences the limit that gets written.
        if ($trained -le 0) {
            try {
                $models = Invoke-RestMethod -Uri "$baseUrl/v1/models" -TimeoutSec 5 -ErrorAction Stop
                if ($models -and $models.data -and $models.data.Count -gt 0) {
                    $m = $models.data[0]
                    if ($m.meta -and $m.meta.n_ctx_train) { $trained = [int]$m.meta.n_ctx_train }
                    elseif ($m.n_ctx_train) { $trained = [int]$m.n_ctx_train }
                }
            } catch { }
        }

        if ($actual -gt 0) { break }
    } catch {
        # Server not up yet (still loading, or it failed to start).
    }
    Start-Sleep -Seconds 2
}

if ($actual -le 0) {
    Write-JsonFile -Path $outcomePath -Data @{
        ok = $false
        requested = $Requested
        actual = 0
        source = ''
        error = "server did not become ready on port $Port within $TimeoutSec s"
    }
    exit 1
}

# ----------------------------------------------------------------- reconcile
$realOutput = Get-OutputBudget -Ctx $actual
$match = ($actual -eq $Requested)

# Always write the REAL values. Even on a match this is a no-op in effect,
# but it makes opencode.runtime.json an accurate record of the running server.
try {
    Write-JsonFile -Path $runtimePath -Data @{
        context = $actual
        output = $realOutput
    }
} catch {
    Write-JsonFile -Path $outcomePath -Data @{
        ok = $false
        requested = $Requested
        actual = $actual
        source = $source
        error = "could not write opencode.runtime.json: $($_.Exception.Message)"
    }
    exit 1
}

# Regenerate opencode.json so limit.context matches the running server.
#
# --runtime is passed explicitly: fix-models.py reads opencode.runtime.json
# from its OWN folder by default, so without this it could pick up a stale
# file and write a limit that disagrees with the running server.
$regenOk = $true
$regenErr = ''
if ($FixModels -and (Test-Path $FixModels)) {
    try {
        $out = & python $FixModels --generate-only --runtime $runtimePath 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            $regenOk = $false
            $regenErr = $out.Trim()
        }
    } catch {
        $regenOk = $false
        $regenErr = $_.Exception.Message
    }
}

Write-JsonFile -Path $outcomePath -Data @{
    ok = $regenOk
    requested = $Requested
    actual = $actual
    trained = $trained
    source = $source
    output = $realOutput
    match = $match
    regenerated = $regenOk
    error = $regenErr
}

exit 0
