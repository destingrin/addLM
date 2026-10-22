<#
.SYNOPSIS
    Verify that OpenCode's `limit.context` matches the context the running
    llama-server ACTUALLY loaded.

.DESCRIPTION
    A wrong `limit.context` is the root cause of the compaction loop described
    in HANDOFF section 8: OpenCode's usable window is (context - output), so a
    limit that disagrees with the server makes every step look like an overflow
    and re-triggers compaction after every single step.

    This check compares three things and fails if they disagree:

      1. the server's real per-slot context   (GET /props ->
         default_generation_settings.n_ctx)
      2. the `limit.context` in the GLOBAL opencode.json
         (%USERPROFILE%\.config\opencode\opencode.json)
      3. the `limit.context` in the project reference copy
         (scripts\opencode.json)

    It also verifies that `limit.output` is smaller than `limit.context`, since
    an output budget >= the context makes the usable window zero.

    This is a regression check: it is meant to be run after any change to the
    launcher, the context calculator or the config generator, and it is exactly
    the check that would have caught the `fix-models.py` path bug (the runtime
    limits file being read from the wrong folder).

.PARAMETER Port
    Port the llama-server is listening on (default 8081).

.PARAMETER ConfigPath
    The GLOBAL opencode.json to check. Defaults to
    %USERPROFILE%\.config\opencode\opencode.json.

.PARAMETER ProjectConfig
    The project reference copy of the config. Defaults to
    <script folder>\opencode.json. Pass -SkipProject to skip it.

.PARAMETER SkipProject
    Do not check the project reference copy of the config.

.PARAMETER Quiet
    Only print the final verdict.

.NOTES
    Exit codes: 0 = OK, 1 = mismatch, 2 = the server is not running,
    3 = the config could not be read.
#>
param(
    [int]$Port = 8081,
    [string]$ConfigPath,
    [string]$ProjectConfig,
    [switch]$SkipProject,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

$scriptDir = $PSScriptRoot

if (-not $ConfigPath) {
    $ConfigPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\opencode\opencode.json'
}
if (-not $PSBoundParameters.ContainsKey('ProjectConfig')) {
    $ProjectConfig = Join-Path $scriptDir 'opencode.json'
}
if ($SkipProject) {
    # NOTE: an empty string cannot be used as the "skip" signal - PowerShell's
    # binder rejects an empty argument for a [string] parameter
    # ("Cannot bind argument to parameter 'ProjectConfig' because it is an
    # empty string"). -SkipProject is the explicit way to opt out.
    $ProjectConfig = $null
}

function Say {
    param([string]$Text, [string]$Colour = 'Gray')
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Colour }
}

# ------------------------------------------------------- 1. the server's truth
$baseUrl = "http://127.0.0.1:$Port"
$realCtx = 0
$realSource = ''
try {
    $props = Invoke-RestMethod -Uri "$baseUrl/props" -TimeoutSec 10 -ErrorAction Stop
    if ($props.default_generation_settings -and $props.default_generation_settings.n_ctx) {
        $realCtx = [int]$props.default_generation_settings.n_ctx
        $realSource = 'props.default_generation_settings.n_ctx'
    }
    elseif ($props.n_ctx) {
        $realCtx = [int]$props.n_ctx
        $realSource = 'props.n_ctx'
    }
} catch {
    Say "ERROR: no llama-server answering on $baseUrl/props" 'Red'
    Say "       Start it with addLM.bat first, or pass -Port <port>." 'Yellow'
    exit 2
}

if ($realCtx -le 0) {
    Say "ERROR: the server did not report a context size ($realSource)." 'Red'
    exit 2
}

Say "Server real context : $realCtx tokens   (source: $realSource)" 'Cyan'

# --------------------------------------------------------- 2. the two configs
function Get-Limit {
    param([string]$Path)
    if (-not $Path) { return $null }
    if (-not (Test-Path $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        # Tolerate a BOM, which Windows PowerShell 5.1's Set-Content writes.
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        $cfg = $text | ConvertFrom-Json
        $m = $cfg.providers.'llama-server'.models.'active-model'
        if (-not $m) { return $null }
        return [pscustomobject]@{
            path    = $Path
            context = [int]$m.limit.context
            output  = [int]$m.limit.output
        }
    } catch {
        return $null
    }
}

$global = Get-Limit -Path $ConfigPath
if (-not $global) {
    Say "ERROR: could not read a 'llama-server' provider with a limit block from:" 'Red'
    Say "       $ConfigPath" 'Yellow'
    exit 3
}

$project = Get-Limit -Path $ProjectConfig

Say "Global  limit.context: $($global.context)  limit.output: $($global.output)   ($($global.path))" 'Gray'
if ($project) {
    Say "Project limit.context: $($project.context)  limit.output: $($project.output)" 'Gray'
}

# ------------------------------------------------------------- 3. the verdict
$problems = @()

if ($global.context -ne $realCtx) {
    $problems += "GLOBAL limit.context = $($global.context) but the server loaded $realCtx."
}
if ($project -and $project.context -ne $realCtx) {
    $problems += "PROJECT limit.context = $($project.context) but the server loaded $realCtx."
}
if ($project -and $global.context -ne $project.context) {
    $problems += "The global and project copies disagree ($($global.context) vs $($project.context))."
}
if ($global.output -ge $global.context) {
    $problems += "limit.output ($($global.output)) is not smaller than limit.context ($($global.context)) - the usable window would be empty."
}
if ($project -and $project.output -ge $project.context) {
    $problems += "PROJECT limit.output ($($project.output)) is not smaller than its limit.context ($($project.context))."
}

if ($problems.Count -eq 0) {
    Say ""
    Say "OK: OpenCode's limit.context ($($global.context)) matches the running server's n_ctx ($realCtx)." 'Green'
    exit 0
}

Say ""
Say "MISMATCH - OpenCode's limits do not match the running server:" 'Red'
foreach ($p in $problems) { Say "  * $p" 'Red' }
Say ""
Say "Fix: re-run the launcher, or run context-sync.ps1 to reconcile:" 'Yellow'
Say "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptDir\context-sync.ps1`" -Port $Port -ScriptDir `"$scriptDir`" -FixModels `"$scriptDir\fix-models.py`"" 'Yellow'
exit 1
