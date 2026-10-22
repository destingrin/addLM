# safetyTest.ps1
# Evaluates a model's refusal behaviour with the standard mlabonne/harmful_behaviors
# benchmark. Starts a throwaway llama-server on a scratch port, runs the benchmark
# against it, then shuts the server down.
#
# Driven by safetyTest.bat. Safe to run while a normal addLM server is up on 8081
# because it uses its own port.

# The benchmark uses the published community method (heretic): 100 test
# prompts, greedy decoding, 100 tokens, and heretic's 33 refusal markers.
# The defaults below match that method.
param(
    [int]$Prompts = 100,
    [int]$MaxTokens = 100,
    [int]$Port = 8099
)

$scriptDir = $PSScriptRoot
$rootDir = Split-Path -Parent $scriptDir

function Resolve-ProjectDir {
    param([string]$Name)
    foreach ($base in @($scriptDir, $rootDir)) {
        if (-not $base) { continue }
        $candidate = Join-Path $base $Name
        # -LiteralPath, NOT -Path: the project can live under a folder whose
        # name contains wildcard characters, e.g. C:\[software]\addLM. With
        # -Path, PowerShell treats "[software]" as a character class, so
        # Test-Path returns False for a folder that plainly exists.
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return (Join-Path $scriptDir $Name)
}

$modelDir = Resolve-ProjectDir 'models'
$llamaCppDir = Resolve-ProjectDir 'llama.cpp'
$llamaServerPath = Join-Path $llamaCppDir 'llama-server.exe'
$safetyTestPath = Join-Path $scriptDir 'safetytest.py'

# --- pre-flight -------------------------------------------------------------
Write-Host "`n--- [ Safety Evaluation Pre-flight ] ---" -ForegroundColor Cyan

if (-not (Test-Path $safetyTestPath)) {
    Write-Host "[FAIL] safetytest.py not found at: $safetyTestPath" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] safetytest.py detected." -ForegroundColor Green

$parquet = @(Get-ChildItem -LiteralPath $scriptDir -Filter 'harmful_*.parquet' -ErrorAction SilentlyContinue)
if ($parquet.Count -eq 0) {
    Write-Host "[FAIL] harmful_behaviors dataset not found next to safetytest.py." -ForegroundColor Red
    Write-Host "       Download from: https://huggingface.co/datasets/mlabonne/harmful_behaviors" -ForegroundColor Yellow
    Write-Host "       and place harmful_train.parquet + harmful_test.parquet in: $scriptDir" -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] harmful_behaviors dataset detected ($($parquet.Count) files)." -ForegroundColor Green

if (-not (Test-Path $llamaServerPath)) {
    Write-Host "[FAIL] llama-server.exe not found at: $llamaServerPath" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] llama-server.exe detected." -ForegroundColor Green

try {
    $pyVer = python --version 2>&1
    Write-Host "[OK] Python detected ($pyVer)." -ForegroundColor Green
} catch {
    Write-Host "[FAIL] Python is not available." -ForegroundColor Red
    exit 1
}

# --- model list -------------------------------------------------------------
if (-not (Test-Path $modelDir)) {
    Write-Host "[FAIL] Models directory not found: $modelDir" -ForegroundColor Red
    exit 1
}

$modelFiles = @(Get-ChildItem -LiteralPath $modelDir -Filter '*.gguf' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike 'mmproj-*' } | Sort-Object LastWriteTime -Descending)

if ($modelFiles.Count -eq 0) {
    Write-Host "[FAIL] No GGUF models found in: $modelDir" -ForegroundColor Red
    exit 1
}

function Format-ModelLabel {
    param([System.IO.FileInfo]$File, [string]$BaseDir)
    $rel = $File.FullName.Substring($BaseDir.Length).TrimStart('\')
    if ($rel.Contains('\')) { return "$rel  [" + (Split-Path $rel -Parent) + "]" }
    return $rel
}

# --- pick the model ---------------------------------------------------------
Write-Host ""
Write-Host 'Available models:' -ForegroundColor Cyan
for ($i = 0; $i -lt $modelFiles.Count; $i++) {
    Write-Host ("  {0}. {1}" -f ($i + 1), (Format-ModelLabel $modelFiles[$i] $modelDir)) -ForegroundColor White
}
Write-Host ""

$choice = Read-Host 'Select model number (Press Enter for 1)'
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }

$idx = 0
if (-not ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $modelFiles.Count)) {
    Write-Host 'Invalid selection!' -ForegroundColor Red
    exit 1
}
$selectedModel = $modelFiles[$idx - 1]
$label = $selectedModel.BaseName

# --- pick the context size --------------------------------------------------
# The server needs a real context; use the same calculator the launcher uses so
# the numbers match. Fall back to 8192 if it cannot be computed.
$ctxSize = 8192
$calcPath = Join-Path $scriptDir 'context-calc.py'
if (Test-Path $calcPath) {
    try {
        # No --llama-dir: context-calc.py finds llama.cpp\ itself
        # (script folder -> project root -> cwd).
        $jsonOut = & python $calcPath $selectedModel.FullName --json 2>$null | Out-String
        $parsed = $jsonOut | ConvertFrom-Json
        if ($parsed -and $parsed.Count -gt 0 -and $parsed[0].recommended_ctx) {
            $ctxSize = [int]$parsed[0].recommended_ctx
        }
    } catch {
        Write-Host "  [WARN] Context calculation failed, using 8192." -ForegroundColor Yellow
    }
}
Write-Host ("Context size: $ctxSize tokens") -ForegroundColor Cyan

# --- start the scratch server ----------------------------------------------
# NOTE: no --gpu-layers here either, for the same reason as addLM.ps1:
# llama.cpp's --fit (on by default) is the safety net that shrinks the context
# until the model fits, but it ABORTS if the user set that parameter
# explicitly ("n_gpu_layers already set by user to -2, abort"). Leaving it at
# the default lets --fit work. The model still offloads every layer.
$serverArgs = @(
    '--model', $selectedModel.FullName,
    '--port', "$Port",
    '--host', '127.0.0.1',
    '--ctx-size', "$ctxSize",
    '--batch-size', '512'
    # NOTE: no DRY / frequency / presence penalties here. The published
    # method (heretic) generates with plain greedy decoding and default
    # repetition penalty, so adding the launcher's anti-repetition flags
    # would make the measurement non-comparable. The benchmark's own
    # temperature=0 is what controls the decoding.
)

$errLog = Join-Path $env:TEMP "safetytest-server-$Port.log"
Write-Host ""
Write-Host "Starting llama-server on port $Port ..." -ForegroundColor Cyan
$proc = Start-Process -FilePath $llamaServerPath -ArgumentList $serverArgs -NoNewWindow -PassThru -RedirectStandardError $errLog

# wait for the server to accept requests
$ready = $false
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 2
    if ($proc.HasExited) { break }
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3 | Out-Null
        $ready = $true
        break
    } catch { }
}

if (-not $ready) {
    Write-Host "[FAIL] llama-server did not come up on port $Port." -ForegroundColor Red
    if (Test-Path $errLog) {
        Write-Host "--- last log lines ---" -ForegroundColor DarkGray
        Get-Content $errLog -Tail 15 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    if (-not $proc.HasExited) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
    exit 1
}

Write-Host "[OK] Server up on port $Port." -ForegroundColor Green
Write-Host ""

# --- run the benchmark ------------------------------------------------------
try {
    & python $safetyTestPath $Port $label $Prompts $MaxTokens
    $code = $LASTEXITCODE
} finally {
    if (-not $proc.HasExited) {
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $errLog -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Server stopped." -ForegroundColor Yellow
exit $code
