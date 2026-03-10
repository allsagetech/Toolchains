<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'openai-gpt-oss-20b'
    RunsOn = 'ubuntu-latest'
}

function Invoke-HuggingFaceSnapshotDownload {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$RepoId,
        [Parameter(Mandatory = $true)][string]$CacheDir,
        [Parameter(Mandatory = $true)][string[]]$AllowPatterns
    )

    $downloadScriptPath = [System.IO.Path]::GetTempFileName()
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $oldRepoId = $env:TLC_HF_REPO_ID
    $oldAllowPatterns = $env:TLC_HF_ALLOW_PATTERNS
    $oldHubCache = $env:HF_HUB_CACHE

    try {
        $downloadScript = @'
import os
from huggingface_hub import snapshot_download

repo_id = os.environ["TLC_HF_REPO_ID"]
allow_patterns = [item for item in os.environ.get("TLC_HF_ALLOW_PATTERNS", "").splitlines() if item]
token = os.environ.get("HF_TOKEN") or None

path = snapshot_download(
    repo_id=repo_id,
    cache_dir=os.environ["HF_HUB_CACHE"],
    token=token,
    allow_patterns=allow_patterns or None,
)

print(path, flush=True)
'@
        Set-Content -LiteralPath $downloadScriptPath -Value $downloadScript -NoNewline

        $env:TLC_HF_REPO_ID = $RepoId
        $env:TLC_HF_ALLOW_PATTERNS = ($AllowPatterns -join "`n")
        $env:HF_HUB_CACHE = $CacheDir

        $downloadProc = Start-Process -FilePath $PythonPath `
            -ArgumentList @('-u', $downloadScriptPath) `
            -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        $heartbeat = 0
        while (-not $downloadProc.HasExited) {
            Start-Sleep -Seconds 60
            $downloadProc.Refresh()
            if (-not $downloadProc.HasExited) {
                $heartbeat += 1
                Write-Host ("Hugging Face download still running (heartbeat {0}, utc={1})." -f $heartbeat, ([datetime]::UtcNow.ToString('o')))
            }
        }

        if (Test-Path -LiteralPath $stdoutPath) {
            Get-Content -LiteralPath $stdoutPath | ForEach-Object { Write-Host $_ }
        }
        if (Test-Path -LiteralPath $stderrPath) {
            Get-Content -LiteralPath $stderrPath | ForEach-Object { Write-Host $_ }
        }

        if ($downloadProc.ExitCode -ne 0) {
            throw "snapshot_download failed with exit code $($downloadProc.ExitCode)."
        }
    }
    finally {
        $env:TLC_HF_REPO_ID = $oldRepoId
        $env:TLC_HF_ALLOW_PATTERNS = $oldAllowPatterns
        $env:HF_HUB_CACHE = $oldHubCache

        foreach ($path in @($downloadScriptPath, $stdoutPath, $stderrPath)) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
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

    $env:HF_HOME = $cacheRoot
    $env:HF_HUB_CACHE = $cacheRoot
    $env:TRANSFORMERS_CACHE = $cacheRoot
    $env:HF_XET_CACHE = $xetCacheRoot
    $env:HF_XET_HIGH_PERFORMANCE = '1'
    if (-not $env:HF_HUB_DOWNLOAD_TIMEOUT) {
        $env:HF_HUB_DOWNLOAD_TIMEOUT = '600'
    }
    if (-not $env:HF_HUB_ETAG_TIMEOUT) {
        $env:HF_HUB_ETAG_TIMEOUT = '30'
    }

    $downloadPatterns = @(
        'LICENSE'
        'README.md'
        'USAGE_POLICY'
        'chat_template.jinja'
        'config.json'
        'generation_config.json'
        'model-*.safetensors'
        'model.safetensors.index.json'
        'special_tokens_map.json'
        'tokenizer.json'
        'tokenizer_config.json'
    )

    Invoke-HuggingFaceSnapshotDownload `
        -PythonPath $venvPython `
        -RepoId 'openai/gpt-oss-20b' `
        -CacheDir $cacheRoot `
        -AllowPatterns $downloadPatterns

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

        $requiredFiles = @(
            'config.json'
            'tokenizer.json'
            'model.safetensors.index.json'
        )
        foreach ($requiredFile in $requiredFiles) {
            $file = Get-ChildItem -LiteralPath $cacheSlug -Recurse -File -Filter $requiredFile -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $file) {
                throw "Required model file missing from Hugging Face cache: $requiredFile"
            }
        }

        $indexFile = Get-ChildItem -LiteralPath $cacheSlug -Recurse -File -Filter 'model.safetensors.index.json' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $indexFile) {
            throw 'Model shard index file missing from Hugging Face cache.'
        }

        $weightIndex = Get-Content -LiteralPath $indexFile.FullName -Raw | ConvertFrom-Json
        if (-not $weightIndex.weight_map) {
            throw 'model.safetensors.index.json is missing weight_map.'
        }
        $requiredShards = @($weightIndex.weight_map.PSObject.Properties.Value | Select-Object -Unique)
        if ($requiredShards.Count -eq 0) {
            throw 'model.safetensors.index.json does not list any shard files.'
        }

        foreach ($requiredShard in $requiredShards) {
            $shard = Get-ChildItem -LiteralPath $cacheSlug -Recurse -File -Filter $requiredShard -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $shard) {
                throw "Required model shard missing from Hugging Face cache: $requiredShard"
            }
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
