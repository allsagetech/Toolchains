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

    $persistentCacheRoot = Join-Path $pkgRoot 'cache'
    $legacyCacheRoot = Join-Path $pkgRoot 'hf-cache'
    $cacheRoot = Join-Path $persistentCacheRoot 'hf-cache'
    $xetCacheRoot = Join-Path $persistentCacheRoot 'hf-xet'
    $manifestPath = Join-Path $pkgRoot 'official-models.manifest.json'
    $toolRoot = Join-Path $pkgRoot '.hf-tools'
    $venvRoot = Join-Path $toolRoot 'venv'

    foreach ($path in @($legacyCacheRoot, $toolRoot)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }

    foreach ($path in @($persistentCacheRoot, $cacheRoot, $xetCacheRoot, $toolRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

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
    $env:HF_HOME = $cacheRoot
    $env:HF_HUB_CACHE = $cacheRoot
    $env:TRANSFORMERS_CACHE = $cacheRoot
    $env:HF_XET_CACHE = $xetCacheRoot

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

    if (Test-Path -LiteralPath $toolRoot) {
        Remove-Item -LiteralPath $toolRoot -Recurse -Force
    }

    Write-TlcVars @{
        env = @{
            HF_HOME                    = '${.}/cache/hf-cache'
            HF_HUB_CACHE               = '${.}/cache/hf-cache'
            TRANSFORMERS_CACHE         = '${.}/cache/hf-cache'
            LOCAL_CODEX_HF_CACHE_SEED  = '${.}/cache/hf-cache'
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

        $cacheCandidates = @(
            (Join-Path $env:HF_HUB_CACHE 'models--openai--gpt-oss-20b'),
            (Join-Path $env:HF_HOME 'models--openai--gpt-oss-20b'),
            (Join-Path $env:HF_HOME 'hub/models--openai--gpt-oss-20b')
        ) | Select-Object -Unique

        $cacheSlug = $cacheCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $cacheSlug) {
            throw "Downloaded Hugging Face cache entry not found. Checked: $($cacheCandidates -join ', ')"
        }
    }
}

function global:Invoke-CustomDockerBuild($tag) {
    $pkgRoot = Get-TlcPkgRoot
    if (-not (Test-Path -LiteralPath $pkgRoot)) {
        throw "Package root does not exist: $pkgRoot"
    }

    $null = Assert-TlcDefinitionFile
    $defPath = Join-Path $pkgRoot '.tlc'
    $defHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $defPath).Hash.ToLowerInvariant()
    $containerName = "toolchains-openai-gpt-oss-20b-" + [Guid]::NewGuid().ToString('n')
    $containerId = $null

    try {
        $containerId = (& docker create --name $containerName ubuntu:22.04 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($containerId)) {
            throw 'docker create failed for openai-gpt-oss-20b image assembly.'
        }

        & docker cp "$pkgRoot/." "${containerId}:/"
        if ($LASTEXITCODE -ne 0) {
            throw "docker cp failed (exit code $LASTEXITCODE) for $containerId"
        }

        $changes = @(
            'LABEL io.allsagetech.toolchain.specVersion=1',
            "LABEL io.allsagetech.toolchain.packageName=$($TlcPackageConfig.Name)",
            "LABEL io.allsagetech.toolchain.packageVersion=$($TlcPackageConfig.Version)",
            'LABEL io.allsagetech.toolchain.tlcPath=/.tlc',
            "LABEL io.allsagetech.toolchain.tlcSha256=$defHash",
            'LABEL toolchain.tlcPath=/.tlc',
            "LABEL toolchain.tlcSha256=$defHash"
        )

        $scriptPath = [System.IO.Path]::GetTempFileName()
        try {
            $scriptLines = @('set -euo pipefail')
            $importLine = "docker export '$containerId' | docker import"
            foreach ($change in $changes) {
                $importLine += " --change '$change'"
            }
            $importLine += " - '$tag'"
            $scriptLines += $importLine

            Set-Content -LiteralPath $scriptPath -Value ($scriptLines -join "`n") -NoNewline
            & bash $scriptPath
            if ($LASTEXITCODE -ne 0) {
                throw "docker import failed (exit code $LASTEXITCODE) for $containerId"
            }
        }
        finally {
            Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        if ($containerId) {
            & docker rm -f $containerId *> $null
        } else {
            & docker rm -f $containerName *> $null
        }
    }
}
