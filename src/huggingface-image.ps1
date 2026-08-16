<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function ConvertTo-TlcDockerPath {
	param(
		[Parameter(Mandatory=$true)][string]$Path
	)

	return $Path.Replace('\', '/').TrimStart('/')
}

function Get-TlcRelativePath {
	param(
		[Parameter(Mandatory=$true)][string]$Root,
		[Parameter(Mandatory=$true)][string]$Path
	)

	$rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
	$pathFull = [System.IO.Path]::GetFullPath($Path)
	try {
		return [System.IO.Path]::GetRelativePath($rootFull, $pathFull)
	} catch {
		if (-not $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
			throw "Path is not under root. Root: $rootFull Path: $pathFull"
		}
		return $pathFull.Substring($rootFull.Length).TrimStart('\', '/')
	}
}

function Add-TlcDockerCopyLine {
	param(
		[Parameter(Mandatory=$true)][System.Collections.ArrayList]$Lines,
		[Parameter(Mandatory=$true)][string]$Source,
		[Parameter(Mandatory=$true)][string]$Destination
	)

	$src = ConvertTo-TlcDockerPath -Path $Source
	$dst = '/' + (ConvertTo-TlcDockerPath -Path $Destination)
	$Lines.Add("COPY `"$src`" `"$dst`"") | Out-Null
}

function Write-HfModelDockerIgnore {
	param(
		[Parameter(Mandatory=$true)][string]$PkgRoot
	)

	$dockerIgnorePath = Join-Path $PkgRoot '.dockerignore'
	$lines = @(
		'.hf-tools',
		'cache/hf-xet',
		'_stage',
		'_stage/**',
		'**/*.partial-*',
		'**/*.tmp',
		'**/*.temp'
	)
	Set-Content -LiteralPath $dockerIgnorePath -Value ($lines -join "`n") -NoNewline
}

function Write-HfModelLayeredDockerfile {
	param(
		[Parameter(Mandatory=$true)][string]$PkgRoot,
		[Parameter(Mandatory=$true)][string]$CacheRoot,
		[Parameter(Mandatory=$true)][string]$CacheSlug
	)

	$cacheCandidates = @(
		(Join-Path $CacheRoot $CacheSlug),
		(Join-Path (Join-Path $CacheRoot 'hub') $CacheSlug)
	) | Select-Object -Unique
	$modelCacheRoot = $cacheCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
	if (-not $modelCacheRoot) {
		throw "Downloaded Hugging Face cache entry not found. Checked: $($cacheCandidates -join ', ')"
	}

	$blobsPath = Join-Path $modelCacheRoot 'blobs'
	if (-not (Test-Path -LiteralPath $blobsPath -PathType Container)) {
		throw "Model blobs directory not found: $blobsPath"
	}

	$blobFiles = Get-ChildItem -LiteralPath $blobsPath -File | Sort-Object Name
	if ($blobFiles.Count -eq 0) {
		throw "No model blobs found in: $blobsPath"
	}

	$safeName = ([string]$TlcPackageConfig.Name) -replace '[^A-Za-z0-9_.-]', '-'
	$dockerfilePath = Join-Path $PkgRoot "Dockerfile.hf-model-$safeName"
	$dockerLines = [System.Collections.ArrayList]::new()
	$dockerLines.Add('FROM ubuntu:22.04@sha256:3b06811b2afd352be909dd088a004166d665dc76d38b13eada33522a9d915c6f') | Out-Null
	Add-TlcDockerCopyLine -Lines $dockerLines -Source '.tlc' -Destination '.tlc'
	Add-TlcDockerCopyLine -Lines $dockerLines -Source 'official-models.manifest.json' -Destination 'official-models.manifest.json'

	foreach ($dirName in @('refs', 'snapshots')) {
		$dirPath = Join-Path $modelCacheRoot $dirName
		if (Test-Path -LiteralPath $dirPath -PathType Container) {
			$relPath = Get-TlcRelativePath -Root $PkgRoot -Path $dirPath
			Add-TlcDockerCopyLine -Lines $dockerLines -Source $relPath -Destination $relPath
		}
	}

	foreach ($blobFile in $blobFiles) {
		$relPath = Get-TlcRelativePath -Root $PkgRoot -Path $blobFile.FullName
		Add-TlcDockerCopyLine -Lines $dockerLines -Source $relPath -Destination $relPath
	}

	Set-Content -LiteralPath $dockerfilePath -Value ($dockerLines -join "`n") -NoNewline
	Write-HfModelDockerIgnore -PkgRoot $PkgRoot
	return $dockerfilePath
}

function Invoke-HfModelLayeredDockerBuild {
	param(
		[Parameter(Mandatory=$true)][string]$Tag,
		[Parameter(Mandatory=$true)][string]$DockerfilePath
	)

	$pkgRoot = Get-TlcPkgRoot
	if (-not (Test-Path -LiteralPath $pkgRoot)) {
		throw "Package root does not exist: $pkgRoot"
	}
	if (-not (Test-Path -LiteralPath $DockerfilePath -PathType Leaf)) {
		throw "Layered Dockerfile not found: $DockerfilePath"
	}

	$null = Assert-TlcDefinitionFile
	$defPath = Join-Path $pkgRoot '.tlc'
	$defHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $defPath).Hash.ToLowerInvariant()
	$dockerArguments = @('build', '-f', $DockerfilePath, '-t', $Tag)
	$labels = @(
		"io.allsagetech.toolchain.packageName=$($TlcPackageConfig.Name)",
		"io.allsagetech.toolchain.packageVersion=$($TlcPackageConfig.Version)",
		'io.allsagetech.toolchain.specVersion=1',
		'io.allsagetech.toolchain.tlcPath=/.tlc',
		"io.allsagetech.toolchain.tlcSha256=$defHash",
		'toolchain.tlcPath=/.tlc',
		"toolchain.tlcSha256=$defHash"
	)
	foreach ($label in $labels) {
		$dockerArguments += @('--label', $label)
	}
	$dockerArguments += @($pkgRoot)

	& docker @dockerArguments
	if ($LASTEXITCODE -ne 0) {
		throw "docker build failed with exit code $LASTEXITCODE for $Tag"
	}
}

function Install-HfModelPackage {
	param(
		[Parameter(Mandatory=$true)][hashtable]$Model
	)

	$repo = [string]$Model.Repo
	if (-not $repo) { throw 'Install-HfModelPackage requires Model.Repo.' }

	$alias = if ($Model.Alias) { [string]$Model.Alias } else { ($repo -split '/')[-1].ToLowerInvariant() }
	$sourceModel = if ($Model.SourceModel) { [string]$Model.SourceModel } else { $repo }
	$officialModel = if ($Model.OfficialModel) { [string]$Model.OfficialModel } else { $repo }
	$cacheSlug = if ($Model.CacheSlug) { [string]$Model.CacheSlug } else { Get-TlcHfModelCacheSlug -Repo $repo }
	$requiresHfToken = [bool]$Model.RequiresHfToken
	$allowPatterns = if ($Model.AllowPatterns) { [string[]]$Model.AllowPatterns } else { Get-TlcHfModelAllowPatterns }

	$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
	if ($isWindowsHost) {
		$TlcPackageConfig.Version = if ($TlcPackageConfig.Latest) { $TlcPackageConfig.Latest.ToString() } else { '0.0.0' }
		$TlcPackageConfig.UpToDate = $true
		Write-Host "Skipping $repo model package build on Windows hosts."
		return
	}

	if ($requiresHfToken -and -not $env:HF_TOKEN) {
		$TlcPackageConfig.Version = if ($TlcPackageConfig.Latest) { $TlcPackageConfig.Latest.ToString() } else { '0.0.0' }
		$TlcPackageConfig.UpToDate = $true
		Write-Host "Skipping $repo model package build because HF_TOKEN is required."
		return
	}

	$python = Get-Command python3 -ErrorAction SilentlyContinue
	if (-not $python) {
		$python = Get-Command python -ErrorAction SilentlyContinue
	}
	if (-not $python) {
		throw "python3 or python is required on PATH to build $repo package."
	}

	$hfHeaders = Get-TlcHfHeaders
	$version = Get-TlcHfModelVersion -Repo $repo -Headers $hfHeaders

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

	$oldHfHome = $env:HF_HOME
	$oldHubCache = $env:HF_HUB_CACHE
	$oldTransformersCache = $env:TRANSFORMERS_CACHE
	$oldXetCache = $env:HF_XET_CACHE
	$oldXetHighPerformance = $env:HF_XET_HIGH_PERFORMANCE
	$oldDownloadTimeout = $env:HF_HUB_DOWNLOAD_TIMEOUT
	$oldEtagTimeout = $env:HF_HUB_ETAG_TIMEOUT
	try {
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

		Invoke-TlcHfSnapshotDownload `
			-PythonPath $venvPython `
			-Repo $repo `
			-CacheDir $cacheRoot `
			-Revision $(if ($Model.Revision) { [string]$Model.Revision } else { $null }) `
			-AllowPatterns $allowPatterns
	}
	finally {
		$env:HF_HOME = $oldHfHome
		$env:HF_HUB_CACHE = $oldHubCache
		$env:TRANSFORMERS_CACHE = $oldTransformersCache
		$env:HF_XET_CACHE = $oldXetCache
		$env:HF_XET_HIGH_PERFORMANCE = $oldXetHighPerformance
		$env:HF_HUB_DOWNLOAD_TIMEOUT = $oldDownloadTimeout
		$env:HF_HUB_ETAG_TIMEOUT = $oldEtagTimeout
	}

	$manifest = [pscustomobject]@{
		models = @(
			[pscustomobject]@{
				alias        = $alias
				repo         = $repo
				source_model = $sourceModel
				cache_slug   = $cacheSlug
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
			LOCAL_CODEX_OFFICIAL_MODEL = $officialModel
		}
	}

	$null = Write-HfModelLayeredDockerfile -PkgRoot $pkgRoot -CacheRoot $cacheRoot -CacheSlug $cacheSlug
}

function Test-HfModelPackageInstall {
	param(
		[Parameter(Mandatory=$true)][string]$Repo,
		[string]$CacheSlug
	)

	if (-not $CacheSlug) {
		$CacheSlug = Get-TlcHfModelCacheSlug -Repo $Repo
	}

	Toolchain exec (Get-TlcPkgUri) {
		if (-not (Test-Path -LiteralPath $env:LOCAL_CODEX_MODEL_MANIFEST)) {
			throw "Model manifest not found: $env:LOCAL_CODEX_MODEL_MANIFEST"
		}

		$manifest = Get-Content -LiteralPath $env:LOCAL_CODEX_MODEL_MANIFEST -Raw | ConvertFrom-Json
		$models = @($manifest.models)
		if ($models.Count -lt 1) {
			throw 'Model manifest is empty.'
		}
		if ($models[0].repo -ne $Repo) {
			throw "Unexpected model repo in manifest: $($models[0].repo)"
		}

		$cacheCandidates = @(
			(Join-Path $env:HF_HUB_CACHE $CacheSlug),
			(Join-Path $env:HF_HOME $CacheSlug),
			(Join-Path (Join-Path $env:HF_HOME 'hub') $CacheSlug)
		) | Select-Object -Unique

		$cachePath = $cacheCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
		if (-not $cachePath) {
			throw "Downloaded Hugging Face cache entry not found. Checked: $($cacheCandidates -join ', ')"
		}
	}
}

function Invoke-HfModelCustomDockerBuild($tag) {
	$pkgRoot = Get-TlcPkgRoot
	if (-not (Test-Path -LiteralPath $pkgRoot)) {
		throw "Package root does not exist: $pkgRoot"
	}

	$safeName = ([string]$TlcPackageConfig.Name) -replace '[^A-Za-z0-9_.-]', '-'
	$dockerfilePath = Join-Path $pkgRoot "Dockerfile.hf-model-$safeName"
	if (-not (Test-Path -LiteralPath $dockerfilePath -PathType Leaf)) {
		$manifestPath = Join-Path $pkgRoot 'official-models.manifest.json'
		if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
			throw "Model manifest not found: $manifestPath"
		}
		$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
		$model = @($manifest.models) | Select-Object -First 1
		if (-not $model.cache_slug) {
			throw "Model manifest is missing cache_slug: $manifestPath"
		}
		$cacheRoot = Join-Path $pkgRoot 'cache/hf-cache'
		$dockerfilePath = Write-HfModelLayeredDockerfile -PkgRoot $pkgRoot -CacheRoot $cacheRoot -CacheSlug ([string]$model.cache_slug)
	}

	Invoke-HfModelLayeredDockerBuild -Tag $tag -DockerfilePath $dockerfilePath
}
