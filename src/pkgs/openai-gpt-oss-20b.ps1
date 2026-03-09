<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'openai-gpt-oss-20b'
    RunsOn = 'ubuntu-latest'
}

function global:Install-TlcPackage {
    $isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    if ($isWindowsHost) {
        $TlcPackageConfig.Version = if ($TlcPackageConfig.Latest) { $TlcPackageConfig.Latest.ToString() } else { '0.0.0' }
        $TlcPackageConfig.UpToDate = $true
        Write-Host 'Skipping openai-gpt-oss-20b package build on Windows hosts.'
        return
    }

    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) {
        $python = Get-Command python -ErrorAction SilentlyContinue
    }
    if (-not $python) {
        throw 'python3 or python is required on PATH to build openai-gpt-oss-20b package.'
    }

    $hfHeaders = @{}
    if ($env:HF_TOKEN) {
        $hfHeaders['Authorization'] = "Bearer $($env:HF_TOKEN)"
    }

    $modelInfo = Invoke-TlcRestMethod -Uri 'https://huggingface.co/api/models/openai/gpt-oss-20b' -Headers $hfHeaders
    $lastModifiedText = [string]$modelInfo.lastModified
    if (-not $lastModifiedText) {
        throw 'Could not determine lastModified for openai/gpt-oss-20b from Hugging Face.'
    }

    $lastModified = [datetime]::Parse($lastModifiedText).ToUniversalTime()
    $buildComponent = [int]$lastModified.ToString('HHmm')
    $version = '{0}.{1}.{2}+{3}' -f $lastModified.Year, $lastModified.Month, $lastModified.Day, $buildComponent

    $TlcPackageConfig.Version = $version
    $TlcPackageConfig.UpToDate = -not ([TlcSemanticVersion]::new($version).LaterThan($TlcPackageConfig.Latest))
    if ($TlcPackageConfig.UpToDate) {
        return
    }

    $pkgRoot = Get-TlcPkgRoot
    New-Item -ItemType Directory -Path $pkgRoot -Force | Out-Null

    $cacheRoot = Join-Path $pkgRoot 'hf-cache'
    $manifestPath = Join-Path $pkgRoot 'official-models.manifest.json'
    $toolRoot = Join-Path $pkgRoot '.hf-tools'
    $venvRoot = Join-Path $toolRoot 'venv'

    foreach ($path in @($cacheRoot, $toolRoot)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }

    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null

    & $python.Source -m venv $venvRoot
    if ($LASTEXITCODE -ne 0) {
        throw "python venv creation failed with exit code $LASTEXITCODE."
    }

    $venvPython = Join-Path $venvRoot 'bin/python'
    if (-not (Test-Path -LiteralPath $venvPython)) {
        throw "Could not find Python executable in virtual environment: $venvPython"
    }

    & $venvPython -m pip install --upgrade pip
    if ($LASTEXITCODE -ne 0) {
        throw "pip upgrade failed with exit code $LASTEXITCODE."
    }

    & $venvPython -m pip install 'huggingface_hub[hf_xet]>=0.32.0'
    if ($LASTEXITCODE -ne 0) {
        throw "pip install huggingface_hub failed with exit code $LASTEXITCODE."
    }

    $hfCliCandidates = @(
        (Join-Path $venvRoot 'bin/hf'),
        (Join-Path $venvRoot 'bin/huggingface-cli')
    )
    $hfCli = $hfCliCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $hfCli) {
        throw "Could not find Hugging Face CLI in virtual environment. Checked: $($hfCliCandidates -join ', ')"
    }

    $downloadArgs = @('download', 'openai/gpt-oss-20b', '--cache-dir', $cacheRoot)
    if ($env:HF_TOKEN) {
        $downloadArgs += @('--token', $env:HF_TOKEN)
    }
    if ($env:HF_HUB_DOWNLOAD_TIMEOUT) {
        $env:HF_HUB_DOWNLOAD_TIMEOUT = $env:HF_HUB_DOWNLOAD_TIMEOUT
    }

    & $hfCli @downloadArgs
    if ($LASTEXITCODE -ne 0) {
        throw "huggingface-cli download openai/gpt-oss-20b failed with exit code $LASTEXITCODE."
    }

    $manifest = [pscustomobject]@{
        models = @(
            [pscustomobject]@{
                alias        = 'gpt-oss-20b'
                repo         = 'openai/gpt-oss-20b'
                source_model = 'openai/gpt-oss-20b'
                cache_slug   = 'models--openai--gpt-oss-20b'
            }
        )
    }
    Set-Content -LiteralPath $manifestPath -Value ($manifest | ConvertTo-Json -Depth 8)

    Write-TlcVars @{
        env = @{
            HF_HOME                    = '${.}/hf-cache'
            HF_HUB_CACHE               = '${.}/hf-cache/hub'
            TRANSFORMERS_CACHE         = '${.}/hf-cache/hub'
            LOCAL_CODEX_HF_CACHE_SEED  = '${.}/hf-cache'
            LOCAL_CODEX_MODEL_MANIFEST = '${.}/official-models.manifest.json'
            LOCAL_CODEX_OFFICIAL_MODEL = 'openai/gpt-oss-20b'
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        if (-not (Test-Path -LiteralPath $env:LOCAL_CODEX_MODEL_MANIFEST)) {
            throw "Model manifest not found: $env:LOCAL_CODEX_MODEL_MANIFEST"
        }

        $manifest = Get-Content -LiteralPath $env:LOCAL_CODEX_MODEL_MANIFEST -Raw | ConvertFrom-Json
        if ($manifest.models.Count -lt 1) {
            throw 'Model manifest is empty.'
        }
        if ($manifest.models[0].repo -ne 'openai/gpt-oss-20b') {
            throw "Unexpected model repo in manifest: $($manifest.models[0].repo)"
        }

        $cacheSlug = Join-Path $env:HF_HUB_CACHE 'models--openai--gpt-oss-20b'
        if (-not (Test-Path -LiteralPath $cacheSlug)) {
            throw "Downloaded Hugging Face cache entry not found: $cacheSlug"
        }
    }
}
