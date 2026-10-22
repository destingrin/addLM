# addLM.ps1
# Launches llama-server with a selected model and an automatically calculated context size.

$scriptDir = $PSScriptRoot
# The project root may be the script folder itself, or its parent
# (layout: <root>\scripts\addLM.ps1 with <root>\models and
# <root>\scripts\llama.cpp - or <root>\llama.cpp).
# NOTE: plain `Split-Path -Parent` is used deliberately. It belongs to the
# ParentSet parameter set, which has no -LiteralPath, and it does NOT treat
# [] as a wildcard: it splits the string literally. (-LiteralPath lives in a
# different parameter set, so combining the two raises
# "AmbiguousParameterSet".) [System.IO.Path]::GetDirectoryName() also works.
$rootDir = Split-Path -Parent $scriptDir

function Resolve-ProjectDir {
    param(
        [string]$Name,
        # When set, a candidate folder that actually holds a matching file wins
        # over one that merely exists.
        [string]$ContentFilter
    )
    # Collect the existing candidates: script folder first, then the project root.
    $candidates = @()
    foreach ($base in @($scriptDir, $rootDir)) {
        if (-not $base) { continue }
        $candidate = Join-Path $base $Name
        # -LiteralPath, NOT -Path: the project can live under a folder whose
        # name contains wildcard characters, e.g. C:\[software]\addLM. With
        # -Path, PowerShell treats "[software]" as a character class, so
        # Test-Path returns False for a folder that plainly exists, and the
        # launcher then concludes llama.cpp\ is missing and re-downloads
        # ~1.2 GB of binaries. -LiteralPath treats the name as a literal.
        if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }
    # Prefer the candidate that really holds the payload. Without this an empty
    # stray folder (scripts\models, left behind by an earlier run) shadows the
    # real one at the project root and every model looks "missing".
    if ($ContentFilter) {
        foreach ($candidate in $candidates) {
            $hit = Get-ChildItem -LiteralPath $candidate -Filter $ContentFilter -Recurse -File -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($hit) { return $candidate }
        }
    }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    # Neither exists yet -> point at the project root, which is the canonical
    # location for models\ and llama.cpp\. Falling back to the script folder
    # would plant a stray empty folder that shadows the root one.
    return (Join-Path $rootDir $Name)
}

# --- Wildcard-path guard ---------------------------------------------------
#
# PowerShell's -Path parameter treats [ ] * and ? as wildcard characters.
# A project living under a folder like C:\[software]\addLM is therefore
# invisible to -Path, and the launcher used to conclude that llama.cpp\ was
# missing and re-download ~1.2 GB of binaries on EVERY launch.
#
# Every path probe in this script now uses -LiteralPath, but a future edit
# could reintroduce the bug. This check makes it loud instead of silent: if
# the two forms disagree, the path contains wildcard characters and every
# -Path call in the script is suspect.
$wildcardSuspect = $false
foreach ($probe in @($scriptDir, $rootDir)) {
    if (-not $probe) { continue }
    if ((Test-Path $probe) -ne (Test-Path -LiteralPath $probe)) {
        $wildcardSuspect = $true
        break
    }
}
if ($wildcardSuspect) {
    Write-Host "[INFO] The project path contains wildcard characters ([ ] * or ?)." -ForegroundColor Cyan
    Write-Host "       Path: $rootDir" -ForegroundColor DarkGray
    Write-Host "       All path probes use -LiteralPath, so this is handled." -ForegroundColor DarkGray
}

$modelDir = Resolve-ProjectDir 'models' -ContentFilter '*.gguf'
$llamaCppDir = Resolve-ProjectDir 'llama.cpp'
$llamaServerPath = Join-Path $llamaCppDir 'llama-server.exe'
$fixModelsPath = Join-Path $scriptDir 'fix-models.py'
$contextCalcPath = Join-Path $scriptDir 'context-calc.py'
# NOTE: the OpenCode config path is not needed here. fix-models.py owns the
# config and writes it to %USERPROFILE%\.config\opencode\opencode.json
# (the documented global location) plus a reference copy in this folder.

function Install-Python {
    Write-Host "`n[Attempting Automatic Installation via 'winget' with elevation...]" -ForegroundColor Cyan
    
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "[FAIL] 'winget' was not found on this system." -ForegroundColor Red
        Write-Host "      -> Action: Please install Python manually from https://www.python.org/downloads/" -ForegroundColor Yellow
        return $false
    }

    # Try to install Python using winget - try specific version IDs since Python.Python.3 may not exist in all winget versions
    Write-Host "Trying winget install with version-specific IDs..." -ForegroundColor Cyan
    
    # Winget Python package IDs are version-specific: Python.Python.3.11, Python.Python.3.12, etc.
    $versionIds = @(
        "Python.Python.3.14",
        "Python.Python.3.13", 
        "Python.Python.3.12",
        "Python.Python.3.11"
    )
    
    $pythonInstalled = $false
    $installedVersion = ""
    
    # Try each version ID
    foreach ($vid in $versionIds) {
        $installCmd = "winget install --id $vid --source winget --silent --accept-source-agreements --accept-package-agreements"
        Write-Host "Attempting: $vid" -ForegroundColor Cyan
        
        try {
            $process = Start-Process powershell -ArgumentList "-NoProfile", "-Command", "$installCmd; Write-Host 'Press any key to continue after installation completes...'; [void][System.Console]::ReadKey()" -Verb RunAs -Wait -PassThru -ErrorAction Stop
            
            if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                Write-Host "`n[SUCCESS] Python installation command completed successfully." -ForegroundColor Green
                $pythonInstalled = $true
                $installedVersion = $vid
                break
            } else {
                Write-Host "[$vid] Not available or install cancelled. " -ForegroundColor Yellow
            }
        } catch {
            Write-Host "[$vid] Failed: $($_.Exception.Message) " -ForegroundColor Yellow
        }
    }
    
    if (-not $pythonInstalled) {
        Write-Host "None of the version-specific IDs worked. Falling back to python.org direct install." -ForegroundColor Yellow
        # Fall back to direct python.org install
        $pythonUrl = "https://www.python.org/ftp/python/3.12.0/python-3.12.0-amd64.exe"
        $downloadPath = Join-Path $env:TEMP "python-installer.exe"
        
        try {
            Write-Host "Downloading Python installer from: $pythonUrl" -ForegroundColor Cyan
            # Suppress the per-chunk progress record (PowerShell 7+ only, so it
            # is applied conditionally) - otherwise a large download floods
            # the console and looks like a hang. See Install-CudaRuntime.
            $pyParams = @{
                Uri         = $pythonUrl
                OutFile     = $downloadPath
                ErrorAction = 'Stop'
            }
            if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('ProgressAction')) {
                $pyParams['ProgressAction'] = 'SilentlyContinue'
            }
            $null = Invoke-WebRequest @pyParams

            Write-Host "Running Python installer..." -ForegroundColor Cyan
            # $null = : the installer's stdout must not leak into the function's
            # return value, or `if (Install-Python)` sees a non-empty array
            # (always truthy) and the failure branch below becomes unreachable.
            $null = & $downloadPath -Quiet -InstallAllUsers $false -PrependPath $true 2>&1
            
            Start-Sleep -Seconds 3
            
            # Verify Python now works
            $versionOutput = python --version 2>&1
            if ($LASTEXITCODE -eq 0 -and $versionOutput) {
                Write-Host "✅ Direct Python install successful: $versionOutput" -ForegroundColor Green
                return $true
            }
        } catch {
            Write-Host "❌ Direct Python install failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        
        Write-Host "⚠️ Python installation failed. Please install manually from: https://www.python.org/downloads/" -ForegroundColor Yellow
        return $false
    }
    
    # --- Attempt to configure Python for current session after winget install ---
    Write-Host "Configuring Python for current session..." -ForegroundColor Cyan
    
    # Common Python install paths
    $pythonSearchPaths = @(
        "$env:USERPROFILE\AppData\Local\Programs\Python\Python312",
        "$env:USERPROFILE\AppData\Local\Programs\Python\Python311",
        "C:\Program Files\Python312",
        "C:\Program Files\Python311"
    )
    
    $pythonExeFound = $false
    
    # Search for python.exe in common locations
    foreach ($path in $pythonSearchPaths) {
        if (Test-Path -LiteralPath $path) {
            $exe = Join-Path $path "python.exe"
            if (Test-Path -LiteralPath $exe) {
                $pythonExeFound = $true
                $pythonDir = $path
                Write-Host "Found Python at: $exe" -ForegroundColor Green
                break
            }
        }
    }
    
    # If not found in common locations, search PATH for python.exe
    if (-not $pythonExeFound) {
        $foundPath = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
        if ($foundPath) {
            $pythonDir = Split-Path $foundPath
            $pythonExeFound = $true
            Write-Host "Found Python via PATH: $foundPath" -ForegroundColor Green
        }
    }
    
    # Add Python directory to current session PATH if found
    if ($pythonExeFound -and $pythonDir) {
        # Check if already in PATH
        $pathEntries = $env:PATH -split ';' | Where-Object { $_.Trim() -ne $pythonDir }
        $env:PATH = "$pythonDir;$($env:PATH)"
        Write-Host "Added Python directory to current session PATH." -ForegroundColor Yellow
    }
    
    # Attempt to disable App Execution Aliases for Python
    try {
        $registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\AppExecutionAlias"
        if (Test-Path -LiteralPath $registryPath) {
            $alias = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\AppExecutionAlias" -Name "python" -ErrorAction SilentlyContinue)
            if ($alias -and $alias.python) {
                Write-Host "Disabling App Execution Alias for Python..." -ForegroundColor Yellow
                Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\AppExecutionAlias" -Name "python" -ErrorAction SilentlyContinue
                Write-Host "App Execution Alias for Python disabled." -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "Note: Could not modify App Execution Aliases (may need admin)." -ForegroundColor Yellow
    }
    
    # Verify Python works in current session
    try {
        $versionOutput = python --version 2>&1
        if ($LASTEXITCODE -eq 0 -and $versionOutput) {
            Write-Host "✅ Python confirmed working: $versionOutput" -ForegroundColor Green
            return $true
        }
    } catch {
        # Ignore
    }
    
    Write-Host "⚠️ Python installed but verification warning - please ensure 'python' is in your PATH." -ForegroundColor Yellow
    Write-Host "   If Python fails, close and reopen this terminal after installation." -ForegroundColor Yellow
    return $true
}

function Install-LlamaCpp {
    Write-Host "`n[Attempting to download llama.cpp binaries from official GitHub releases...]" -ForegroundColor Cyan
    
    # Install target: the project root, next to `models\`. llama.cpp\ and
    # models\ are siblings at the root of the project, and the scripts live
    # in scripts\ one level below. Resolve-ProjectDir searches the script
    # folder first and then the project root, so a fresh install at the root
    # is found on the next run.
    $llamaCppDir = Join-Path $rootDir 'llama.cpp'
    $llamaServerExe = Join-Path $llamaCppDir 'llama-server.exe'

    # A plain assignment here would create a FUNCTION-LOCAL variable that
    # shadows the script-scope $llamaCppDir. The caller then keeps testing
    # the old path, finds nothing, and reports "[FAIL] llama-server.exe still
    # not found after installation attempt." even though the download and
    # extraction both succeeded. Publish the new location to the script scope
    # so the post-install verification looks where the files actually are.
    $script:llamaCppDir = $llamaCppDir
    $script:llamaServerPath = $llamaServerExe
    
    # Create llama.cpp directory if it doesn't exist
    if (-not (Test-Path -LiteralPath $llamaCppDir)) {
        $null = New-Item -ItemType Directory -Path $llamaCppDir -Force
        Write-Host "Created llama.cpp directory: $llamaCppDir" -ForegroundColor Green
    }
    
    # Detect GPU to choose appropriate binary
    $gpuType = "cpu"  # default
    try {
        $gpu = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA|AMD|Intel' } | Select-Object -First 1
        if ($gpu) {
            $gpuName = $gpu.Name.ToLower()
            if ($gpuName -match 'nvidia') {
                $gpuType = "cuda"
            } elseif ($gpuName -match 'amd|radeon') {
                $gpuType = "vulkan"
            } elseif ($gpuName -match 'intel') {
                $gpuType = "vulkan"  # Intel Arc supports Vulkan
            }
        }
    } catch {
        Write-Host "Could not detect GPU, defaulting to CPU build" -ForegroundColor Yellow
    }
    
    # Try GitHub API to get ALL releases (including pre-releases/nightlies which have binaries)
    $headers = @{
        "Accept" = "application/vnd.github.v3+json"
        "User-Agent" = "llama.cpp-addLM-script"
    }
    
    $apiUrl = "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=20"
    $downloadUrl = $null
    $releaseTag = $null
    $selectedRelease = $null
    
    try {
        Write-Host "Fetching releases from GitHub..." -ForegroundColor Cyan
        $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
        
        # Find the latest pre-release (nightly build) that has binary assets
        # Nightly builds have tags like "b11635", "b11720", etc. and contain binaries
        foreach ($rel in $releases) {
            if ($rel.prerelease -and $rel.tag_name -match '^b\d+$') {
                # Check if this release has the assets we need
                $baseName = "llama-$($rel.tag_name)-bin-win"
                $hasCuda = $rel.assets | Where-Object { $_.name -like "$baseName-cuda-*-x64.zip" }
                $hasVulkan = $rel.assets | Where-Object { $_.name -like "$baseName-vulkan-x64.zip" }
                $hasCpu = $rel.assets | Where-Object { $_.name -like "$baseName-cpu-x64.zip" }
                
                if ($gpuType -eq "cuda" -and $hasCuda) {
                    $selectedRelease = $rel
                    break
                } elseif ($gpuType -eq "vulkan" -and $hasVulkan) {
                    $selectedRelease = $rel
                    break
                } elseif ($gpuType -eq "cpu" -and $hasCpu) {
                    $selectedRelease = $rel
                    break
                } elseif (-not $selectedRelease -and ($hasCuda -or $hasVulkan -or $hasCpu)) {
                    # Keep as fallback
                    $selectedRelease = $rel
                }
            }
        }
        
        if ($selectedRelease) {
            $releaseTag = $selectedRelease.tag_name
            Write-Host "Selected nightly build: $releaseTag" -ForegroundColor Green
            
            # Build asset names for this release
            $baseName = "llama-$releaseTag-bin-win"
            $assetNames = switch ($gpuType) {
                "cuda"     { @("$baseName-cuda-12.4-x64.zip", "$baseName-cuda-12-x64.zip", "$baseName-cuda-cu12.4-x64.zip") }
                "vulkan"   { @("$baseName-vulkan-x64.zip") }
                default    { @("$baseName-cpu-x64.zip") }
            }
            
            # Try to find matching asset
            foreach ($name in $assetNames) {
                $asset = $selectedRelease.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
                if ($asset) {
                    $downloadUrl = $asset.browser_download_url
                    $assetName = $name
                    Write-Host "Found asset: $assetName" -ForegroundColor Green
                    break
                }
            }
            
            # CPU fallback
            if (-not $downloadUrl) {
                Write-Host "[WARN] No $gpuType asset found, trying CPU fallback..." -ForegroundColor Yellow
                $cpuAssets = @("$baseName-cpu-x64.zip")
                foreach ($name in $cpuAssets) {
                    $asset = $selectedRelease.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
                    if ($asset) {
                        $downloadUrl = $asset.browser_download_url
                        $assetName = $name
                        Write-Host "Found CPU fallback asset: $assetName" -ForegroundColor Green
                        break
                    }
                }
            }
        }
    } catch {
        Write-Host "[WARN] GitHub API failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    # Fallback: try known recent nightly tags directly
    if (-not $downloadUrl) {
        Write-Host "[WARN] Trying known recent nightly tags..." -ForegroundColor Yellow
        
        $knownTags = @("b11752", "b11751", "b11750", "b11748", "b11721", "b11720", "b11719", "b11712", "b11635", "b11633", "b11641", "b11435", "b11000", "b10000")
        
        foreach ($tag in $knownTags) {
            $baseName = "llama-$tag-bin-win"
            $testAssets = switch ($gpuType) {
                "cuda"     { @("$baseName-cuda-12.4-x64.zip", "$baseName-cuda-12-x64.zip", "$baseName-cuda-cu12.4-x64.zip") }
                "vulkan"   { @("$baseName-vulkan-x64.zip") }
                default    { @("$baseName-cpu-x64.zip") }
            }
            
            foreach ($name in $testAssets) {
                $testUrl = "https://github.com/ggml-org/llama.cpp/releases/download/$tag/$name"
                try {
                    $test = Invoke-WebRequest -Uri $testUrl -Method Head -Headers $headers -ErrorAction Stop
                    if ($test.StatusCode -eq 200) {
                        $downloadUrl = $testUrl
                        $assetName = $name
                        $releaseTag = $tag
                        Write-Host "Found working nightly: $releaseTag / $assetName" -ForegroundColor Green
                        break
                    }
                } catch { }
            }
            
            if ($downloadUrl) { break }
        }
    }
    
    if (-not $downloadUrl) {
        Write-Host "[FAIL] Could not find any working download URL." -ForegroundColor Red
        Write-Host "      -> Please manually download from: https://github.com/ggml-org/llama.cpp/releases" -ForegroundColor Yellow
        Write-Host "      -> Look for a pre-release (nightly) with tag like b11720" -ForegroundColor Yellow
        return $false
    }
    
    $zipPath = Join-Path $env:TEMP "$assetName"
    
    try {
        Write-Host "Downloading $assetName from $downloadUrl ..." -ForegroundColor Cyan
        
        # Download with progress bar (ASCII for compatibility)
        try {
            # NOTE: -ProgressAction only exists in PowerShell 7+, not Windows PowerShell 5.1.
            # Detect and use it only when available so the download does not fail on 5.1.
            $iwrParams = @{
                Uri             = $downloadUrl
                OutFile         = $zipPath
                Headers         = $headers
                ErrorAction     = 'Stop'
            }
            if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('ProgressAction')) {
                $iwrParams['ProgressAction'] = 'SilentlyContinue'
            }
            # $null = : the response object must not leak into the function's
            # return value. PowerShell's `return` does NOT discard earlier
            # pipeline output, so without this the function returns
            # @(<WebResponseObject>, $false) - a non-empty array is always
            # truthy, so the caller's failure branch would be unreachable.
            $null = Invoke-WebRequest @iwrParams
        } catch {
            # Fallback: use System.Net.WebClient with progress events
            $client = New-Object System.Net.WebClient
            $client.Headers.Add("User-Agent", "llama.cpp-addLM-script")
            $client.Headers.Add("Accept", "application/vnd.github.v3+json")
            
            $global:lastPercent = -1
            $downloadEvent = Register-ObjectEvent -InputObject $client -EventName DownloadProgressChanged -Action {
                $e = $Event.SourceEventArgs
                $percent = $e.ProgressPercentage
                if ($percent -ne $global:lastPercent) {
                    $global:lastPercent = $percent
                    $filled = $percent / 2
                    $empty = 50 - $filled
                    $bar = "#" * $filled + "-" * $empty
                    $mbReceived = [math]::Round($e.BytesReceived / 1MB, 1)
                    $mbTotal = [math]::Round($e.TotalBytesToReceive / 1MB, 1)
                    Write-Host "`r  [$bar] $percent% ($mbReceived MB / $mbTotal MB)" -NoNewline -ForegroundColor Cyan
                }
            }
            
            $client.DownloadFileTaskAsync($downloadUrl, $zipPath).Wait()
            Unregister-Event -SourceIdentifier $downloadEvent.Name
            Write-Host ""  # New line after progress bar
        }
        
        Write-Host "Extracting to $llamaCppDir ..." -ForegroundColor Cyan
        Expand-Archive -Path $zipPath -DestinationPath $llamaCppDir -Force -ErrorAction Stop
        
        # Verify llama-server.exe exists
        if (Test-Path -LiteralPath $llamaServerExe) {
            Write-Host "✅ llama-server.exe installed successfully at: $llamaServerExe" -ForegroundColor Green
            
            # Clean up zip
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            return $true
        } else {
            Write-Host "[FAIL] Extraction completed but llama-server.exe not found at expected path." -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host "[FAIL] Failed to download/extract llama.cpp binaries: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "      -> You can manually download from: https://github.com/ggml-org/llama.cpp/releases" -ForegroundColor Yellow
        Write-Host "      -> Look for asset matching: $assetName" -ForegroundColor Yellow
        return $false
    }
}

function Install-CudaRuntime {
    # Since llama.cpp b11xxx the Windows CUDA builds NO LONGER bundle the CUDA
    # runtime (cudart64_12.dll / cublas64_12.dll / cublasLt64_12.dll).
    # They ship in a separate "cudart-llama-bin-win-cuda-12.4-x64.zip" package.
    # Without those DLLs the ggml-cuda.dll fails to load (Windows error 126) and
    # llama-server silently falls back to CPU-only.
    Write-Host "`n[Downloading CUDA runtime libraries for the NVIDIA backend...]" -ForegroundColor Cyan

    $headers = @{
        "Accept" = "application/vnd.github.v3+json"
        "User-Agent" = "llama.cpp-addLM-script"
    }

    $cudartAssetName = $null
    $cudartUrl = $null
    $releaseTag = $null

    try {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=20" -Headers $headers -ErrorAction Stop
        foreach ($rel in $releases) {
            if ($rel.prerelease -and $rel.tag_name -match '^b\d+$') {
                $asset = $rel.assets | Where-Object { $_.name -eq "cudart-llama-bin-win-cuda-12.4-x64.zip" } | Select-Object -First 1
                if ($asset) {
                    $cudartAssetName = $asset.name
                    $cudartUrl = $asset.browser_download_url
                    $releaseTag = $rel.tag_name
                    break
                }
            }
        }
    } catch {
        Write-Host "[WARN] Could not query GitHub releases: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if (-not $cudartUrl) {
        Write-Host "[FAIL] Could not locate the cudart CUDA runtime package." -ForegroundColor Red
        Write-Host "      -> Manually download 'cudart-llama-bin-win-cuda-12.4-x64.zip' from" -ForegroundColor Yellow
        Write-Host "         https://github.com/ggml-org/llama.cpp/releases and extract it into $llamaCppDir" -ForegroundColor Yellow
        return $false
    }

    $zipPath = Join-Path $env:TEMP $cudartAssetName
    try {
        Write-Host "Downloading $cudartAssetName (release $releaseTag) ..." -ForegroundColor Cyan

        # NOTE: this download is ~114 MB. Without suppressing the progress
        # record, Windows PowerShell 5.1 renders a per-chunk progress bar that
        # floods the console with per-request write log lines (the wording is
        # locale-dependent) and makes the launcher look hung. -ProgressAction
        # only exists in PowerShell 7+, so it is applied conditionally -
        # exactly like Install-LlamaCpp does.
        $iwrParams = @{
            Uri         = $cudartUrl
            OutFile     = $zipPath
            Headers     = $headers
            ErrorAction = 'Stop'
        }
        if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('ProgressAction')) {
            $iwrParams['ProgressAction'] = 'SilentlyContinue'
        }
        # $null = : the response object must not leak into the function's
        # return value, or the function returns @(<WebResponseObject>, $true)
        # and the caller's failure branch becomes unreachable.
        $null = Invoke-WebRequest @iwrParams

        Write-Host "Extracting to $llamaCppDir ..." -ForegroundColor Cyan
        Expand-Archive -Path $zipPath -DestinationPath $llamaCppDir -Force -ErrorAction Stop
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        $required = @('cudart64_12.dll', 'cublas64_12.dll', 'cublasLt64_12.dll')
        $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path -Path $llamaCppDir -ChildPath $_)) })
        if ($missing.Count -eq 0) {
            Write-Host "✅ CUDA runtime installed: $($required -join ', ')" -ForegroundColor Green
            return $true
        }
        Write-Host "[FAIL] Still missing after extraction: $($missing -join ', ')" -ForegroundColor Red
        return $false
    } catch {
        Write-Host "[FAIL] Failed to install CUDA runtime: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Test-GpuBackend {
    # Verify that llama-server can actually see the GPU.
    # The ggml backend is loaded dynamically, so a missing CUDA runtime DLL makes
    # the process fall back to CPU without any visible error.
    Write-Host "`n--- [ GPU Backend Check ] ---" -ForegroundColor Cyan

    try {
        $deviceOutput = & $llamaServerPath --list-devices 2>&1 | Out-String
    } catch {
        Write-Host "[WARN] Could not run 'llama-server --list-devices': $($_.Exception.Message)" -ForegroundColor Yellow
        return $true
    }

    $hasCuda = $deviceOutput -match 'CUDA\d'
    $hasVulkan = $deviceOutput -match 'Vulkan'
    $hasNone = $deviceOutput -match '\(none\)'

    if ($hasCuda) {
        Write-Host "[OK] NVIDIA CUDA backend detected:" -ForegroundColor Green
        Write-Host $deviceOutput.TrimEnd() -ForegroundColor Green
        return $true
    }

    if ($hasVulkan) {
        Write-Host "[OK] Vulkan backend detected:" -ForegroundColor Green
        Write-Host $deviceOutput.TrimEnd() -ForegroundColor Green
        return $true
    }

    # No GPU visible -> most likely a missing CUDA runtime DLL.
    Write-Host "[FAIL] No GPU detected by llama-server. It will run on CPU only." -ForegroundColor Red
    Write-Host $deviceOutput.TrimEnd() -ForegroundColor Red

    $cudaDlls = @('cudart64_12.dll', 'cublas64_12.dll', 'cublasLt64_12.dll')
    $missing = @($cudaDlls | Where-Object { -not (Test-Path -LiteralPath (Join-Path -Path $llamaCppDir -ChildPath $_)) })
    if ($missing.Count -gt 0) {
        Write-Host "      -> Root cause: missing CUDA runtime DLL(s): $($missing -join ', ')" -ForegroundColor Yellow
        Write-Host "      -> Attempting automatic download..." -ForegroundColor Cyan
        if (Install-CudaRuntime) {
            Write-Host "      -> Re-checking device list..." -ForegroundColor Cyan
            $retry = & $llamaServerPath --list-devices 2>&1 | Out-String
            if ($retry -match 'CUDA\d') {
                Write-Host "[OK] GPU is now detected:" -ForegroundColor Green
                Write-Host $retry.TrimEnd() -ForegroundColor Green
                return $true
            }
            Write-Host "[FAIL] CUDA runtime installed but the GPU is still not listed." -ForegroundColor Red
            Write-Host $retry.TrimEnd() -ForegroundColor Red
            return $false
        }
        return $false
    }

    Write-Host "      -> CUDA runtime DLLs are present, so this is a different problem." -ForegroundColor Yellow
    Write-Host "      -> Check that your NVIDIA driver is up to date and that the GPU is not disabled." -ForegroundColor Yellow
    return $false
}

function Test-Environment {
    $criticalError = $false
    Write-Host "`n--- [ Pre-flight Check ] ---" -ForegroundColor Cyan

    # 1. Check Python (Rigorous check)
    $pythonOk = $false
    $pythonVersion = ""
    try {
        $versionOutput = python --version 2>&1
        if ($LASTEXITCODE -eq 0 -and $versionOutput -match 'Python') {
            $pythonOk = $true
            $pythonVersion = $versionOutput.ToString().Trim()
        }
    } catch {
        $pythonOk = $false
    }

    if (-not $pythonOk) {
        Write-Host "[FAIL] Python is not properly installed or not in your PATH." -ForegroundColor Red
        Write-Host "      -> Action: Install Python from https://www.python.org/downloads/" -ForegroundColor Yellow
        Write-Host "      -> TIP: Disable 'App Execution Aliases' for Python in Windows Settings if already installed." -ForegroundColor Yellow
        
        $choice = Read-Host "`nWould you like to attempt to install Python automatically via 'winget'? (Y/N)"
        if ($choice -eq 'Y' -or $choice -eq 'y') {
            if (Install-Python) {
                # After install (which may include direct python.org fallback), re-verify Python in current session
                try {
                    $versionOutput = python --version 2>&1
                    if ($LASTEXITCODE -eq 0 -and $versionOutput -match 'Python') {
                        Write-Host "✅ Python verified after installation: $($versionOutput.Trim())" -ForegroundColor Green
                        $pythonOk = $true
                    } else {
                        Write-Host "⚠️ Python installed but verification failed - the direct python.org fallback may have been attempted." -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "⚠️ Error during post-install verification." -ForegroundColor Yellow
                }
            }
        }
        if (-not $pythonOk) {
            $criticalError = $true
        }
    } else {
        Write-Host "[OK] Python detected ($pythonVersion)." -ForegroundColor Green
    }

    # 2. Check llama-server.exe
    if (-not (Test-Path -LiteralPath $llamaServerPath)) {
        Write-Host "[WARN] llama-server.exe not found at: $llamaServerPath" -ForegroundColor Yellow
        Write-Host "      -> Attempting to auto-download from official GitHub releases..." -ForegroundColor Cyan
        
        if (Install-LlamaCpp) {
            # Re-check after installation
            if (Test-Path -LiteralPath $llamaServerPath) {
                Write-Host "[OK] llama-server.exe installed and detected." -ForegroundColor Green
            } else {
                Write-Host "[FAIL] llama-server.exe still not found after installation attempt." -ForegroundColor Red
                $criticalError = $true
            }
        } else {
            Write-Host "[FAIL] Automatic download failed. Please manually download from:" -ForegroundColor Red
            Write-Host "      https://github.com/ggml-org/llama.cpp/releases" -ForegroundColor Yellow
            Write-Host "      Extract to: $llamaCppDir" -ForegroundColor Yellow
            $criticalError = $true
        }
    } else {
        Write-Host "[OK] llama-server.exe detected." -ForegroundColor Green
    }

    # 3. Check fix-models.py
    if (-not (Test-Path -LiteralPath $fixModelsPath)) {
        Write-Host "[FAIL] fix-models.py is missing from this folder." -ForegroundColor Red
        Write-Host "      -> Action: Ensure all project files are correctly placed." -ForegroundColor Yellow
        $criticalError = $true
    } else {
        Write-Host "[OK] fix-models.py detected." -ForegroundColor Green
    }

    # 4. Check Models (Warning only - llama-server can auto-download from Hugging Face via -hf flag)
    if (-not (Test-Path -LiteralPath $modelDir)) {
        Write-Host "[WARN] 'models' folder is missing ($modelDir)." -ForegroundColor Yellow
        Write-Host "      -> Action: Create that folder and put your .gguf files in it, or use the -hf flag with a Hugging Face model ID." -ForegroundColor Yellow
        # NOTE: the folder is deliberately NOT created here. Creating it in the
        # script folder left an empty stray folder behind, which then shadowed
        # the real one at the project root and made every model look missing.
        # See "Path resolution" in the handoff.
    } elseif (-not (Get-ChildItem -LiteralPath $modelDir -Filter *.gguf -ErrorAction SilentlyContinue)) {
        Write-Host "[WARN] 'models' folder is empty. No local GGUF files found." -ForegroundColor Yellow
        Write-Host "      -> Searched: $modelDir" -ForegroundColor Yellow
        Write-Host "      -> You can still run llama-server with a Hugging Face model ID (e.g., -hf unsloth/Qwen2.5-7B-Instruct-GGUF:Q4_K_M)" -ForegroundColor Cyan
    } else {
        Write-Host "[OK] Models folder has local GGUF files ($modelDir)." -ForegroundColor Green
    }

    # 5. Check the offline context calculator
    if (Test-Path -LiteralPath $contextCalcPath) {
        Write-Host "[OK] context-calc.py detected." -ForegroundColor Green
    } else {
        Write-Host "[WARN] context-calc.py is missing - context size will fall back to manual grades." -ForegroundColor Yellow
        Write-Host "      -> Restore it from the project folder to get automatic context sizing." -ForegroundColor Yellow
    }

    # 6. Check that the GPU backend actually loads (dynamic DLL load -> silent CPU fallback)
    if (Test-GpuBackend) {
        Write-Host "[OK] GPU backend available." -ForegroundColor Green
    } else {
        Write-Host "[FAIL] No usable GPU backend. The server would run on CPU only." -ForegroundColor Red
        $criticalError = $true
    }

    Write-Host "---------------------------`n" -ForegroundColor Cyan
    return -not $criticalError
}

function Wait-ForKey {
    # $Host.UI.RawUI.ReadKey() throws when there is no console - a non-
    # interactive host, a scheduled task, a CI runner, or a redirected
    # session. The unguarded calls used to abort the script with a raw
    # exception in exactly those situations, hiding the real error message
    # that was printed just before it.
    try {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        # No console to wait on - nothing to do.
    }
}

# --- START EXECUTION ---

# Run the pre-flight check
if (-not (Test-Environment)) {
    Write-Host "Environment check failed or installation triggered. Please fix the issues above and try again." -ForegroundColor Red
    Write-Host "Press any key to exit..."
    Wait-ForKey
    exit 1
}

# If we get here, environment check passed (or Python was installed and verified)
# Now proceed with the main workflow

# Step 1: Ensure opencode.json is up to date
Write-Host 'Updating configuration...' -ForegroundColor Cyan
python "$fixModelsPath" --generate-only

if ($LASTEXITCODE -ne 0) {
    Write-Host 'Failed to generate configuration!' -ForegroundColor Red
    Wait-ForKey
    exit 1
}

# Step 2: Discover models
if (-not (Test-Path -LiteralPath $modelDir)) {
    Write-Host "Models directory not found: $modelDir" -ForegroundColor Red
    Write-Host "Create that folder and put your .gguf files in it." -ForegroundColor Yellow
    # NOTE: not created here on purpose - see the note in Test-Environment.
}

# Recurse into sub-folders: many model packs ship as <models>\<ModelName>\<ModelName>.gguf
# (e.g. gemma-4-12B-it-QAT-GGUF, Qwen3.5-9B-GGUF, MiMo-V2.6-Distill-Qwen-9B-Q8_0).
# mmproj-* files are vision projectors and are not selectable models.
$modelFiles = @(Get-ChildItem -LiteralPath $modelDir -Filter '*.gguf' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike 'mmproj-*' } | Sort-Object LastWriteTime -Descending)

# Show the sub-folder when a model lives in one, so identically-named files stay distinguishable.
function Format-ModelLabel {
    param([System.IO.FileInfo]$File, [string]$BaseDir)
    $rel = $File.FullName.Substring($BaseDir.Length).TrimStart('\')
    if ($rel.Contains('\')) {
        $folder = Split-Path $rel -Parent
        return "$rel  [$folder]"
    }
    return $rel
}

# Step 3: Model Selection
if ($modelFiles.Count -gt 0) {
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
        Wait-ForKey
        exit 1
    }

    $selectedModel = $modelFiles[$idx - 1]

    # Step 4: Context size - calculated from the GGUF metadata + real VRAM budget.
    # context-calc.py reads the model's trained context length from the GGUF header and
    # asks llama.cpp (llama-fit-params.exe) how much VRAM each context size needs.
    # Nothing is hardcoded, so this adapts to any model you drop into the folder.
    $autoCtx = 0
    if (Test-Path -LiteralPath $contextCalcPath) {
        Write-Host ""
        Write-Host 'Calculating optimal context size for this model...' -ForegroundColor Cyan
        try {
            # No --llama-dir: context-calc.py finds llama.cpp\ itself
            # (script folder -> project root -> cwd).
            $jsonOut = & python $contextCalcPath $selectedModel.FullName --json 2>$null | Out-String
            $parsed = $jsonOut | ConvertFrom-Json
            if ($parsed -and $parsed.Count -gt 0) {
                $rec = $parsed[0]
                if ($rec.recommended_ctx) {
                    $autoCtx = [int]$rec.recommended_ctx
                    Write-Host ("  Trained context : {0}" -f $rec.trained_ctx) -ForegroundColor DarkGray
                    foreach ($n in $rec.notes) { Write-Host ("  Note            : {0}" -f $n) -ForegroundColor DarkGray }
                    Write-Host ("  Free VRAM       : {0} MiB" -f $rec.free_vram_mib) -ForegroundColor DarkGray
                    Write-Host ("  Optimal context : {0} tokens (GPU {1} MiB)" -f $rec.recommended_ctx, $rec.gpu_mib_at_recommended) -ForegroundColor Green
                } else {
                    Write-Host '  Could not size this model to the available VRAM.' -ForegroundColor Yellow
                    if ($rec.does_not_fit) {
                        Write-Host ("  Even {0} tokens needs {1} MiB." -f $rec.does_not_fit[0], $rec.does_not_fit[1]) -ForegroundColor Yellow
                    }
                }
            }
        } catch {
            Write-Host "  Context calculation failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($autoCtx -gt 0) {
        Write-Host ""
        Write-Host 'Context size options:' -ForegroundColor Cyan
        Write-Host ("  1. {0} tokens (automatic - recommended)" -f $autoCtx) -ForegroundColor White
        Write-Host '  2. 8192 tokens (Small / fastest)' -ForegroundColor White
        Write-Host '  3. 16384 tokens (Medium)' -ForegroundColor White
        Write-Host '  4. 32768 tokens (Large)' -ForegroundColor White
        Write-Host ''

        $gradeChoice = Read-Host 'Select context size (1-4, default 1)'
        if ([string]::IsNullOrWhiteSpace($gradeChoice)) { $gradeChoice = '1' }

        switch ($gradeChoice.Trim()) {
            '2' { $ctxSize = 8192 }
            '3' { $ctxSize = 16384 }
            '4' { $ctxSize = 32768 }
            default { $ctxSize = $autoCtx }
        }
    } else {
        # Fallback if the calculator is unavailable or could not size the model.
        Write-Host ""
        Write-Host 'Context size grades:' -ForegroundColor Cyan
        Write-Host '  1. 8192 tokens (Small)' -ForegroundColor White
        Write-Host '  2. 16384 tokens (Medium)' -ForegroundColor White
        Write-Host '  3. 32768 tokens (Large)' -ForegroundColor White
        Write-Host ''

        $gradeChoice = Read-Host 'Select context grade (1-3, default 1)'
        if ([string]::IsNullOrWhiteSpace($gradeChoice)) { $gradeChoice = '1' }

        $ctxSize = 8192
        switch ($gradeChoice.Trim()) {
            '2' { $ctxSize = 16384 }
            '3' { $ctxSize = 32768 }
            default { $ctxSize = 8192 }
        }
    }

    # Step 5: Launch llama-server
    Write-Host ""
    Write-Host "Starting: $($selectedModel.Name)" -ForegroundColor Green
    Write-Host "Context size: $ctxSize tokens" -ForegroundColor Cyan
    Write-Host ""

    # Output budget. OpenCode's usable window is (context - output); an output
    # budget larger than the context makes every step look like an overflow and
    # re-triggers compaction after each one.
    $outputBudget = 2048
    if ($ctxSize -le 8192) { $outputBudget = 1024 }
    elseif ($ctxSize -le 16384) { $outputBudget = 1536 }

    # Write the real launch parameters so fix-models.py can declare an accurate
    # limit.context / limit.output for OpenCode. Without this, OpenCode assumes
    # the built-in fallback of context=200000 / output=32000, which makes its
    # usable window negative for a local model and causes a compaction loop.
    #
    # NOTE: Windows PowerShell 5.1's -Encoding UTF8 writes a BOM, which makes
    # Python's json.loads() fail and silently fall back to the defaults.
    # Write the file as plain ASCII without a BOM.
    try {
        $runtime = '{' + "`n" +
                   '  "context": ' + [int]$ctxSize + ',' + "`n" +
                   '  "output": ' + [int]$outputBudget + "`n" +
                   '}'
        [System.IO.File]::WriteAllText(
            (Join-Path $scriptDir 'opencode.runtime.json'),
            $runtime,
            (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Host "  [WARN] Could not write opencode.runtime.json: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Regenerate opencode.json now that the real limits are known.
    python "$fixModelsPath" --generate-only 2>$null | Out-Null

    # Repetition control.
    # Measured on this machine (6 prompts x 3 samples, no-EOS rate):
    #   default            -> 3/18   (default  repeat 1.1 -> 4/18  (WORSE)
    #   dry 0.8            -> 2/18
    #   dry 0.8 + repeat 1.1 -> 1/18
    #   freq 0.1 + pres 0.1  -> 1/15
    # repeat_penalty alone makes it worse on these reasoning models, so it is
    # left at 1.0 and DRY + frequency/presence penalties carry the work.
    # NOTE: named $serverArgs, not $args. $args is a PowerShell AUTOMATIC
    # variable (the script's own arguments); assigning to it is fragile and
    # can break in a way that is hard to diagnose.
    #
    # --gpu-layers is deliberately NOT passed.
    #
    # llama.cpp's --fit (default: on) is the upstream safety net that shrinks
    # the context / tensor split until the model fits in device memory. But
    # common/fit.cpp refuses to modify any parameter the user set explicitly
    # and ABORTS the whole fit when it cannot, logging:
    #
    #   W common_fit_params: failed to fit params to free device memory:
    #     n_gpu_layers already set by user to -2, abort
    #
    # Passing '--gpu-layers all' therefore DISABLED the safety net this
    # project was relying on. Measured on this machine (RTX 5070, 12199 MiB),
    # Qwen3.8-9B-Q8_0 at --ctx-size 262144:
    #
    #   with    '--gpu-layers all' -> fit aborted, server NEVER STARTED
    #   without '--gpu-layers all' -> fit ran, server started (10438 MiB used)
    #
    # Leaving n_gpu_layers at its default (auto) lets --fit pick the split,
    # and on a model that fits it still offloads every layer to the GPU.
    # --ctx-size is still passed explicitly, and upstream does NOT shrink an
    # explicit --ctx-size (common/fit.h: "the context size which is modified
    # if and only if equal to 0"), so the size chosen above is honoured.
    $serverArgs = @(
        '--model', $selectedModel.FullName,
        '--port', '8081',
        '--host', '127.0.0.1',
        '--ctx-size', "$ctxSize",
        '--keep', '8',
        '--batch-size', '512',
        '--n-predict', "$outputBudget",
        '--dry-multiplier', '0.8',
        '--frequency-penalty', '0.1',
        '--presence-penalty', '0.1',
        '--agent'
    )

    Write-Host 'Launching llama-server...' -ForegroundColor Cyan

    # The server is started in the BACKGROUND so the real context can be read
    # from it (see the context-sync step below) before the script blocks.
    #
    # Start-Process is used rather than a job so the server keeps running when
    # this script exits, and so its stdout/stderr can be captured to a log
    # instead of scrolling the console away.
    $serverLog = Join-Path $scriptDir 'llama-server.log'
    $serverProc = $null
    try {
        # NOTE: -WindowStyle and -NoNewWindow are MUTUALLY EXCLUSIVE in
        # Windows PowerShell 5.1 - passing both throws
        # "Parameter set cannot be resolved using the specified named
        # parameters." -NoNewWindow is used alone so the server inherits this
        # console and the user still sees it.
        #
        # The server's own --log-file is used instead of -RedirectStandardOutput
        # / -RedirectStandardError. Those two parameters resolve their target
        # with PowerShell's wildcard-aware path handling, so they fail with
        # "FileOpenFailure" when the project lives under a folder whose name
        # contains [ ] * or ? (e.g. C:\[software]\addLM) - even when the file
        # already exists. llama.cpp opens the file itself with plain fopen(),
        # which is literal-safe, so the log lands in the project folder
        # regardless of the path.
        $serverArgs += @('--log-file', $serverLog)
        $serverProc = Start-Process -FilePath $llamaServerPath -ArgumentList $serverArgs `
            -PassThru -NoNewWindow -ErrorAction Stop
    } catch {
        # Fall back to a hidden window if -NoNewWindow is not available.
        try {
            $serverProc = Start-Process -FilePath $llamaServerPath -ArgumentList $serverArgs `
                -WindowStyle Hidden -PassThru -ErrorAction Stop
        } catch {
            Write-Host "  [FAIL] Could not start llama-server: $($_.Exception.Message)" -ForegroundColor Red
            Wait-ForKey
            exit 1
        }
    }

    # Step 6: Reconcile the PREDICTED context with the ACTUAL one.
    #
    # The size chosen above is a PREDICTION. The server has the final say:
    # llama.cpp's --fit may settle on a different context, and only the server
    # knows what it actually loaded. llama-server publishes the truth on
    # GET /props -> default_generation_settings.n_ctx.
    #
    # If the two differ, opencode.json is rewritten with the real value, so
    # OpenCode's `limit.context` can never disagree with the running server.
    # A wrong limit is what makes OpenCode's usable window (context - output)
    # degenerate and re-trigger compaction after every single step.
    $contextSyncPath = Join-Path $scriptDir 'context-sync.ps1'
    if (Test-Path -LiteralPath $contextSyncPath) {
        Write-Host ''
        Write-Host 'Waiting for the server to report its real context...' -ForegroundColor Cyan
        $syncOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $contextSyncPath `
            -Port 8081 -Requested $ctxSize -Output $outputBudget `
            -ScriptDir $scriptDir -FixModels $fixModelsPath 2>&1 | Out-String

        $actualFile = Join-Path $scriptDir 'opencode.runtime.actual.json'
        if (Test-Path -LiteralPath $actualFile) {
            try {
                # NOTE: the file is written by context-sync.ps1 in a SEPARATE
                # process, so it may still be being written when we read it.
                # A partial read parses as an error ("Raw" / "Unexpected end of
                # JSON input"), which is not a real failure - it just means we
                # were too fast. Retry a few times before giving up.
                $actual = $null
                for ($attempt = 1; $attempt -le 10; $attempt++) {
                    try {
                        $raw = Get-Content -LiteralPath $actualFile -Raw -Encoding UTF8
                        if ($raw) { $actual = $raw | ConvertFrom-Json }
                        if ($actual) { break }
                    } catch {
                        $actual = $null
                    }
                    Start-Sleep -Milliseconds 300
                }
                if (-not $actual) { throw 'could not parse the context-sync result file' }
                if ($actual.ok -and $actual.actual -gt 0) {
                    if ($actual.match) {
                        Write-Host ("  Real context : {0} tokens (matches the request)" -f $actual.actual) -ForegroundColor Green
                    } else {
                        Write-Host ("  Real context : {0} tokens (requested {1} - upstream adjusted it)" -f $actual.actual, $actual.requested) -ForegroundColor Yellow
                        Write-Host ("  -> opencode.json limit.context updated to {0}" -f $actual.actual) -ForegroundColor Yellow
                    }
                    if ($actual.trained -gt 0) {
                        Write-Host ("  Trained limit: {0} tokens" -f $actual.trained) -ForegroundColor DarkGray
                    }
                } else {
                    Write-Host ("  [WARN] Could not confirm the real context: {0}" -f $actual.error) -ForegroundColor Yellow
                    Write-Host '         The predicted context is still in opencode.json.' -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  [WARN] Could not read the context-sync result: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        } else {
            Write-Host '  [WARN] context-sync did not produce a result file.' -ForegroundColor Yellow
        }
    } else {
        Write-Host '  [WARN] context-sync.ps1 not found - the predicted context is used as-is.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Server is running in the background. OpenCode can be started now.' -ForegroundColor Green
    Write-Host ("  Log: {0}" -f $serverLog) -ForegroundColor DarkGray
    Write-Host ''

    # Wait for the server to exit, so the script behaves like the old
    # foreground launch did (Ctrl+C or closing the window stops it).
    if ($serverProc) {
        try {
            $serverProc.WaitForExit()
        } catch {
            # The handle may already be gone; fall back to a blocking wait.
            while ($true) {
                $p = Get-Process -Id $serverProc.Id -ErrorAction SilentlyContinue
                if (-not $p) { break }
                Start-Sleep -Seconds 2
            }
        }
    }

    Write-Host ""
    Write-Host 'Server stopped.' -ForegroundColor Yellow
} else {
    Write-Host "No models available to launch." -ForegroundColor Red
    Write-Host "Place .gguf files in the 'models/' folder and re-run the script." -ForegroundColor Yellow
    Wait-ForKey
}
