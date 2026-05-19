<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

Class TlcSemanticVersion : System.IComparable {

	[int]$Major = 0
	[int]$Minor = 0
	[int]$Patch = 0
	[int]$Build = 0

	hidden init([string]$tag, [string]$pattern) {
		if ($tag -match $pattern) {
			$this.Major = if ($Matches[1]) { $Matches[1] } else { 0 }
			$this.Minor = if ($Matches[2]) { $Matches[2] } else { 0 }
			$this.Patch = if ($Matches[3]) { $Matches[3] } else { 0 }
			$this.Build = if ($Matches[4]) { [Regex]::Replace("$($Matches[4])", '[^0-9]+', '') } else { 0 }
		}
	}

	TlcSemanticVersion([string]$tag, [string]$pattern) {
		$this.init($tag, $pattern)
	}

	TlcSemanticVersion([string]$version) {
		$this.init($version, '^([0-9]+)\.([0-9]+)\.([0-9]+)([+.][0-9]+)?$')
	}

	TlcSemanticVersion() { }

	[bool] LaterThan([object]$Obj) {
		return $this.CompareTo($obj) -lt 0
	}

	[int] CompareTo([object]$Obj) {
		if ($Obj -isnot $this.GetType()) {
			throw "cannot compare types $($Obj.GetType()) and $($this.GetType())"
		} elseif ((($i = $Obj.Major.CompareTo($this.Major)) -ne 0) -or (($i = $Obj.Minor.CompareTo($this.Minor)) -ne 0) -or (($i = $Obj.Patch.CompareTo($this.Patch)) -ne 0)) {
			return $i
		}
		return $Obj.Build.CompareTo($this.Build)
	}

	[bool] Equals([object]$Obj) {
		return $Obj -is $this.GetType() -and $Obj.Major -eq $this.Major -and $Obj.Minor -eq $this.Minor -and $Obj.Patch -eq $this.Patch -and $Obj.Build -eq $this.Build
	}

	[string] ToString() {
		return "$($this.Major).$($this.Minor).$($this.Patch)$(if ($this.Build) {"+$($this.Build)"})"
	}

}

function Get-TlcGitHubHeaders {
	$headers = @{
		"User-Agent" = "allsagetech-toolchains"
		"Accept" = "application/vnd.github+json"
		"X-GitHub-Api-Version" = "2022-11-28"
	}
	$token = $env:GH_TOKEN
	if (-not $token) { $token = $env:GITHUB_TOKEN }
	if ($token) {
		$headers["Authorization"] = "Bearer $token"
	}
	return $headers
}

function Invoke-TlcRestMethod {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Uri,
		[hashtable]$Headers,
		[int]$TimeoutSec = 120,
		[int]$MaxRetries = 8,
		[int]$RetryDelaySeconds = 2
	)
	$ErrorActionPreference = 'Stop'
	for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
		try {
			$Params = @{ Uri = $Uri; ErrorAction = 'Stop'; TimeoutSec = $TimeoutSec }
			if ($Headers) { $Params.Headers = $Headers }
			return (Invoke-RestMethod @Params)
		} catch {
			$statusCode = $null
			try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
			if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and ($statusCode -notin 408, 429)) { throw }

			if ($attempt -ge $MaxRetries) { throw }
			$delay = [math]::Min(60, $RetryDelaySeconds * [math]::Pow(2, ($attempt - 1)))
			$retryAfter = $null
			try { $retryAfter = $_.Exception.Response.Headers['Retry-After'] } catch { }
			if ($retryAfter) {
				[int]$raSec = 0
				if ([int]::TryParse([string]$retryAfter, [ref]$raSec)) {
					$delay = [math]::Max($delay, $raSec)
				} else {
					try {
						$raDate = [datetime]::Parse([string]$retryAfter)
						$raDelta = [int]([math]::Ceiling(($raDate.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds))
						if ($raDelta -gt 0) { $delay = [math]::Max($delay, $raDelta) }
					} catch { }
				}
			}
			Write-Host "request failed (attempt $attempt/$MaxRetries); retrying in $delay sec: $($_.Exception.Message)"
			Start-Sleep -Seconds $delay
		}
	}
}

function Invoke-TlcWebRequest {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Uri,
		[string]$OutFile,
		[hashtable]$Headers,
		[int]$TimeoutSec = 300,
		[int]$MaxRetries = 8,
		[int]$RetryDelaySeconds = 2
	)
	$ErrorActionPreference = 'Stop'
	$hasUseBasicParsing = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('UseBasicParsing')

	$cacheFile = $null
	if ($OutFile) {
		try {
			$ext = [IO.Path]::GetExtension($OutFile)
			if (-not $ext) { $ext = [IO.Path]::GetExtension(([Uri]$Uri).AbsolutePath) }
			$cacheFile = Get-TlcCachePathForUri -Uri $Uri -Extension ($ext.TrimStart('.'))
			if ($cacheFile -and (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
				Copy-Item -LiteralPath $cacheFile -Destination $OutFile -Force
				return [pscustomobject]@{ StatusCode = 200; FromCache = $true; Path = $OutFile }
			}
		} catch { }
	}
	for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
		try {
			$Params = @{ Uri = $Uri; ErrorAction = 'Stop'; TimeoutSec = $TimeoutSec }
			if ($OutFile) { $Params.OutFile = $OutFile }
			if ($Headers) { $Params.Headers = $Headers }
			if ($hasUseBasicParsing) { $Params.UseBasicParsing = $true }
			$resp = (Invoke-WebRequest @Params)
			if ($OutFile -and $cacheFile) { try { Copy-Item -LiteralPath $OutFile -Destination $cacheFile -Force } catch { } }
			return $resp
		} catch {
			$statusCode = $null
			try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
			if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and ($statusCode -notin 408, 429)) { throw }

			if ($attempt -ge $MaxRetries) { throw }
			$delay = [math]::Min(60, $RetryDelaySeconds * [math]::Pow(2, ($attempt - 1)))
			$retryAfter = $null
			try { $retryAfter = $_.Exception.Response.Headers['Retry-After'] } catch { }
			if ($retryAfter) {
				[int]$raSec = 0
				if ([int]::TryParse([string]$retryAfter, [ref]$raSec)) {
					$delay = [math]::Max($delay, $raSec)
				} else {
					try {
						$raDate = [datetime]::Parse([string]$retryAfter)
						$raDelta = [int]([math]::Ceiling(($raDate.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds))
						if ($raDelta -gt 0) { $delay = [math]::Max($delay, $raDelta) }
					} catch { }
				}
			}
			Write-Host "request failed (attempt $attempt/$MaxRetries); retrying in $delay sec: $($_.Exception.Message)"
			Start-Sleep -Seconds $delay
		}
	}
}

function Get-DockerToken($scope) {
	$resp = Invoke-TlcWebRequest -Uri "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${scope}:pull"
	return ($resp.content | ConvertFrom-Json).token
}

function Get-DockerTags([string]$repo) {
  $tags = @()
  $url = "https://hub.docker.com/v2/repositories/$repo/tags/?page_size=100"

  while ($url) {
    $resp = Invoke-TlcRestMethod -Uri $url
    $tags += $resp.results.name
    $url = $resp.next
  }

  return @{ tags = $tags }
}

function Write-TlcVars($vars) {
	$pkgRoot = Get-TlcPkgRoot
	$text = $vars | ConvertTo-Json -Depth 50 -Compress

	$rootsToReplace = @()
	try { $rootsToReplace += [System.IO.Path]::GetFullPath($pkgRoot) } catch { if ($pkgRoot) { $rootsToReplace += $pkgRoot } }
	try { $rootsToReplace += (Resolve-Path $pkgRoot -ErrorAction Stop).Path } catch { }
	$rootsToReplace = $rootsToReplace | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
	foreach ($r in $rootsToReplace) {
		$escaped = $r.Replace('\', '\\')
		$text = $text.Replace($escaped, '${.}')
	}

	$text = [regex]::Replace($text, '(?i)(?<![A-Za-z]:)\\\\pkg', '${.}')

	if (-not (Test-Path -LiteralPath $pkgRoot -PathType Container)) {
		New-Item -ItemType Directory -Path $pkgRoot -Force | Out-Null
	}

	[IO.File]::WriteAllText((Join-Path $pkgRoot '.tlc'), $text)
}

function Get-TlcHfHeaders {
	$headers = @{
		"User-Agent" = "allsagetech-toolchains"
	}
	if ($env:HF_TOKEN) {
		$headers["Authorization"] = "Bearer $($env:HF_TOKEN)"
	}
	return $headers
}

function Get-TlcHfModelCacheSlug {
	param(
		[Parameter(Mandatory=$true)][string]$Repo
	)
	return "models--$($Repo.Replace('/', '--'))"
}

function Get-TlcHfModelVersion {
	param(
		[Parameter(Mandatory=$true)][string]$Repo,
		[hashtable]$Headers
	)

	$modelInfo = Invoke-TlcRestMethod -Uri "https://huggingface.co/api/models/$Repo" -Headers $Headers
	$lastModifiedText = [string]$modelInfo.lastModified
	if (-not $lastModifiedText) {
		throw "Could not determine lastModified for $Repo from Hugging Face."
	}

	$lastModified = [datetime]::Parse($lastModifiedText).ToUniversalTime()
	$buildComponent = [int]$lastModified.ToString('HHmm')
	return '{0}.{1}.{2}+{3}' -f $lastModified.Year, $lastModified.Month, $lastModified.Day, $buildComponent
}

function Get-TlcHfModelAllowPatterns {
	return @(
		'LICENSE'
		'LICENSE.*'
		'README.md'
		'USAGE_POLICY'
		'chat_template.jinja'
		'config.json'
		'generation_config.json'
		'merges.txt'
		'model.safetensors'
		'model-*.safetensors'
		'*.safetensors.index.json'
		'special_tokens_map.json'
		'tokenizer.json'
		'tokenizer.model'
		'tokenizer_config.json'
		'vocab.*'
	)
}

function Invoke-TlcHfSnapshotDownload {
	param(
		[Parameter(Mandatory=$true)][string]$PythonPath,
		[Parameter(Mandatory=$true)][string]$Repo,
		[Parameter(Mandatory=$true)][string]$CacheDir,
		[string]$Revision,
		[string[]]$AllowPatterns
	)

	$downloadScriptPath = [System.IO.Path]::GetTempFileName()
	$stdoutPath = [System.IO.Path]::GetTempFileName()
	$stderrPath = [System.IO.Path]::GetTempFileName()
	$oldRepo = $env:TLC_HF_REPO_ID
	$oldRevision = $env:TLC_HF_REVISION
	$oldAllowPatterns = $env:TLC_HF_ALLOW_PATTERNS
	$oldHubCache = $env:HF_HUB_CACHE

	try {
		$downloadScript = @'
import os
from huggingface_hub import snapshot_download

repo_id = os.environ["TLC_HF_REPO_ID"]
revision = os.environ.get("TLC_HF_REVISION") or None
allow_patterns = [item for item in os.environ.get("TLC_HF_ALLOW_PATTERNS", "").splitlines() if item]
token = os.environ.get("HF_TOKEN") or None

path = snapshot_download(
    repo_id=repo_id,
    revision=revision,
    cache_dir=os.environ["HF_HUB_CACHE"],
    token=token,
    allow_patterns=allow_patterns or None,
)

print(path, flush=True)
'@
		Set-Content -LiteralPath $downloadScriptPath -Value $downloadScript -NoNewline

		$env:TLC_HF_REPO_ID = $Repo
		$env:TLC_HF_REVISION = $Revision
		$env:TLC_HF_ALLOW_PATTERNS = if ($AllowPatterns) { ($AllowPatterns -join "`n") } else { $null }
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
			throw "snapshot_download $Repo failed with exit code $($downloadProc.ExitCode)."
		}
	}
	finally {
		$env:TLC_HF_REPO_ID = $oldRepo
		$env:TLC_HF_REVISION = $oldRevision
		$env:TLC_HF_ALLOW_PATTERNS = $oldAllowPatterns
		$env:HF_HUB_CACHE = $oldHubCache

		foreach ($path in @($downloadScriptPath, $stdoutPath, $stderrPath)) {
			if ($path -and (Test-Path -LiteralPath $path)) {
				Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
			}
		}
	}
}

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
		'cache/hf-xet'
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
	$dockerLines.Add('FROM ubuntu:22.04') | Out-Null
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
	$args = @('build', '-f', $DockerfilePath, '-t', $Tag)
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
		$args += @('--label', $label)
	}
	$args += @($pkgRoot)

	& docker @args
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


function Set-RegistryKey($path, $name, $value) {
	if (!(Test-Path $path)) {
		New-Item -Path $path -Force | Out-Null
	}
	New-ItemProperty -Path $path -Name $name -Value $value -Force | Out-Null
}

function Find-LatestTag([object[]]$List, [string]$TagProperty, [string]$TagPattern) {
	$LatestAsset = $List[0]
	$LatestVersion = [TlcSemanticVersion]::new($LatestAsset.$TagProperty, $TagPattern)
	for ($i = 1; $i -lt $List.Count; $i += 1) {
		$version = [TlcSemanticVersion]::new($List[$i].$TagProperty, $TagPattern)
		if ($LatestVersion.CompareTo($version) -gt 0) {
			$LatestAsset = $List[$i]
			$LatestVersion = $version
		}
	}
	return @{
		Item = $LatestAsset
		Version = $LatestVersion
	}
}

function Get-GitHubRelease {
	param (
		[Parameter(Mandatory=$true)][string]$Owner,
		[Parameter(Mandatory=$true)][string]$Repo,
		[Parameter(Mandatory=$true)][string]$AssetPattern,
		[Parameter(Mandatory=$true)][string]$TagPattern
	)
	$headers = Get-TlcGitHubHeaders
	$page = 1
	$releases = @()
	do {
		$chunk = Invoke-TlcRestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases?per_page=100&page=$page" -Headers $headers
		if ($chunk) { $releases += $chunk }
		$page += 1
	} while ($chunk.Count -gt 0 -and $page -le 20)

	$filtered = @($releases | Where-Object { $_.tag_name -match $TagPattern -and -not $_.prerelease })
	if ($filtered.Count -eq 0) {
		Write-Error "Failed to find a matching GitHub Release tag for $Owner/$Repo (pattern: $TagPattern)"
		return
	}
	$Latest = Find-LatestTag $filtered 'tag_name' $TagPattern
	foreach ($Asset in $Latest.item.assets) {
		if ($Asset.name -match $AssetPattern) {
			return @{
				URL = $Asset.browser_download_url
				Name = $Asset.name
				Identifier = $Latest.item.tag_name
				Version = $Latest.version
			}
		}
	}
	Write-Error "Failed to find a GitHub Release asset for $Owner/$Repo (asset pattern: $AssetPattern)"
}

function Get-GitHubTag {
	param (
		[Parameter(Mandatory=$true)][string]$Owner,
		[Parameter(Mandatory=$true)][string]$Repo,
		[Parameter(Mandatory=$true)][string]$TagPattern
	)
	$headers = Get-TlcGitHubHeaders
	$i = 1
	$Tags = @()
	do {
		Write-Output "page=$i"
		$Page = Invoke-TlcRestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/tags?per_page=100&page=$i" -Headers $headers
		$Tags += $Page
		$i++
		if ($i -gt 200) { break }
	} while ($Page.Count -gt 0)
	$Latest = Find-LatestTag $Tags 'name' $TagPattern
	if ($Latest) {
		return @{
			Name = $Latest.item.name
			Version = $Latest.version
		}
	}
	Write-Error "Failed to find a GitHub Tag for $Owner $Repo"
}

function Install-BuildTool {
	param (
		[Parameter(Mandatory=$true)][string]$AssetName,
		[Parameter(Mandatory=$true)][string]$AssetURL,
		[string]$ToolDir = '\pkg'
	)
	$Asset = "$env:Temp\$AssetName"
	Write-Output "downloading $AssetURL to $Asset"
	Invoke-TlcWebRequest -Uri $AssetURL -OutFile $Asset
	Expand-Archive $Asset $ToolDir
}

function Get-DotNetReleaseAsset {
	param(
		[Parameter(Mandatory=$true)][ValidateSet('sdk', 'runtime')][string]$Product,
		[string]$Rid = 'win-x64',
		[string]$Extension = '.zip',
		[switch]$IncludePreview
	)

	$index = Invoke-TlcRestMethod -Uri 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json'
	$channels = @($index.'releases-index') | Where-Object {
		$phase = [string]$_.'support-phase'
		($phase -ne 'eol') -and ($IncludePreview -or $phase -ne 'preview')
	} | Sort-Object -Property @{
		Expression = {
			$parts = ([string]$_.'channel-version').Split('.')
			[version]::new([int]$parts[0], [int]$parts[1], 0)
		}
		Descending = $true
	}

	foreach ($channel in $channels) {
		$releaseData = Invoke-TlcRestMethod -Uri ([string]$channel.'releases.json')
		$releases = @($releaseData.releases) | Sort-Object -Property @{
			Expression = {
				try { [datetime]::Parse([string]$_.'release-date') } catch { [datetime]::MinValue }
			}
			Descending = $true
		}

		foreach ($release in $releases) {
			$assets = @()
			if ($Product -eq 'sdk') {
				if ($release.sdk) { $assets += $release.sdk }
				if ($release.sdks) { $assets += @($release.sdks) }
			} else {
				if ($release.runtime) { $assets += $release.runtime }
			}

			foreach ($asset in $assets) {
				$version = [string]$asset.version
				if ([string]::IsNullOrWhiteSpace($version)) { continue }
				if ((-not $IncludePreview) -and $version.Contains('-')) { continue }

				$file = @($asset.files) | Where-Object {
					([string]$_.rid) -eq $Rid -and
					([string]$_.url) -and
					([string]$_.url).EndsWith($Extension, [System.StringComparison]::OrdinalIgnoreCase)
				} | Select-Object -First 1
				if (-not $file) { continue }

				$name = [string]$file.name
				if ([string]::IsNullOrWhiteSpace($name)) {
					try { $name = [IO.Path]::GetFileName(([Uri][string]$file.url).AbsolutePath) } catch { }
				}
				if ([string]::IsNullOrWhiteSpace($name)) {
					$name = "dotnet-$Product-$version-$Rid$Extension"
				}

				return @{
					Name = $name
					URL = [string]$file.url
					Version = [TlcSemanticVersion]::new($version)
					VersionText = $version
					ChannelVersion = [string]$channel.'channel-version'
					ReleaseDate = [string]$release.'release-date'
				}
			}
		}
	}

	throw "Failed to find a .NET $Product $Rid$Extension release asset from official release metadata."
}


function Get-TlcPkgRoot {
    $root = $env:TLC_PKG_ROOT
    if (-not $root) { $root = '\pkg' }

    try {
        return [System.IO.Path]::GetFullPath($root)
    } catch {
        return $root
    }
}


function Get-TlcCacheRoot {
    $root = $env:TLC_CACHE_ROOT
    if (-not $root) {
        $root = Join-Path (Get-TlcPkgRoot) 'cache'
    }
    if (-not (Test-Path $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return $root
}

function Get-TlcCachePathForUri {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Extension
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($Uri)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    if (-not $Extension) { $Extension = '' }
    if ($Extension -and (-not $Extension.StartsWith('.'))) { $Extension = '.' + $Extension }
    return (Join-Path (Get-TlcCacheRoot) ($hex + $Extension))
}

function Get-TlcPkgUri {
	$root = Get-TlcPkgRoot
	if ($IsWindows) {
		$path = $root.Replace('\\', '/')
		if ($path -match '^[A-Za-z]:/') {
			return "file:///$path"
		}
		if (-not $path.StartsWith('/')) { $path = "/$path" }
		return "file:///$path"
	}
	$path = $root.Replace('\\', '/')
	if (-not $path.StartsWith('/')) { $path = "/$path" }
	return "file://$path"
}

function Expand-TlcEnvValue {
	param(
		[AllowNull()]
		[object]$Value,

		[Parameter(Mandatory=$true)]
		[string]$PkgRoot
	)

	if ($null -eq $Value) { return $null }

	$expandOne = {
		param([string]$s)
		$out = $s.Replace('${.}', $PkgRoot)
		$out = [regex]::Replace($out, '(?i)(?<![A-Za-z]:)\\pkg', { param($m) $PkgRoot })
		return $out
	}

	if ($Value -is [string]) {
		return (& $expandOne $Value)
	}

	if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
		$out = @()
		foreach ($x in $Value) {
			if ($null -eq $x) { continue }
			if ($x -isnot [string]) { throw "env value array must contain only strings" }
			$out += (& $expandOne $x)
		}
		return $out
	}

	throw "env value must be a string or array of strings"
}

function Invoke-TlcLocalExec {
	param(
		[Parameter(Mandatory)][string]$Spec,
		[Parameter(Mandatory)][ScriptBlock]$Block
	)

	$specText = $Spec.Trim()
	$cfgName = $null
	$src = $specText
	if ($specText -match '^(.*?)<\s*(.+)$') {
		$src = $Matches[1].Trim()
		$cfgName = $Matches[2].Trim()
	}

	$pkgRoot = Get-TlcPkgRoot
	$defPath = Join-Path $pkgRoot '.tlc'
	if (-not (Test-Path -LiteralPath $defPath -PathType Leaf)) {
		throw "toolchain definition not found: $defPath"
	}

	$json = (Get-Content -LiteralPath $defPath -Raw).Trim()
	$def = $json | ConvertFrom-Json -AsHashtable
	if (-not $def.ContainsKey('env')) {
		throw "toolchain definition missing required top-level 'env' object: $defPath"
	}

	$envMap = $def['env']
	if ($cfgName) {
		if (-not $def.ContainsKey($cfgName)) {
			throw "toolchain config not found in ${defPath}: $cfgName"
		}
		$cfg = $def[$cfgName]
		if ($cfg -isnot [hashtable] -or -not $cfg.ContainsKey('env')) {
			throw "toolchain config '$cfgName' missing required 'env' object: $defPath"
		}
		$envMap = $cfg['env']
	}

	$originals = @{}
	try {
		foreach ($k in $envMap.Keys) {
			$name = [string]$k
			$orig = Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
			$originals[$name] = if ($orig) { @{ Exists = $true; Value = $orig.Value } } else { @{ Exists = $false } }

			$val = Expand-TlcEnvValue -Value $envMap[$k] -PkgRoot $pkgRoot
			if ($name -ieq 'path') {
				$sep = [System.IO.Path]::PathSeparator
				$oldPath = (Get-Item -LiteralPath 'Env:Path' -ErrorAction SilentlyContinue).Value
				if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
					$val = ($val -join $sep)
				}
				if ([string]::IsNullOrWhiteSpace([string]$val)) {
					continue
				}
				$valStr = [string]$val
				$valStr = $valStr.Trim($sep)
				$merged = if ([string]::IsNullOrWhiteSpace($oldPath)) { $valStr } else { "$valStr$sep$oldPath" }
				Set-Item -LiteralPath 'Env:Path' -Value $merged
			} else {
				if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
					$val = ($val -join [System.IO.Path]::PathSeparator)
				}
				if ($null -eq $val) {
					Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
				} else {
					Set-Item -LiteralPath "Env:$name" -Value $val
				}
			}
		}

		& $Block
	}
	finally {
		foreach ($name in $originals.Keys) {
			$info = $originals[$name]
			if ($info.Exists) {
				if ($null -eq $info.Value) {
					Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
				} else {
					Set-Item -LiteralPath "Env:$name" -Value $info.Value
				}
			} else {
				Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
			}
		}
	}
}

function Toolchain {
	[CmdletBinding()]
	param(
		[Parameter(Position=0, Mandatory)][string]$Verb,
		[Parameter(Position=1, Mandatory)][string]$Spec,
		[Parameter(Position=2, Mandatory)][ScriptBlock]$Block
	)

	if ($Verb -ne 'exec') {
		throw "Toolchains wrapper only supports: Toolchain exec <spec> { ... }"
	}

	Invoke-TlcLocalExec -Spec $Spec -Block $Block
}



function Test-TlcToolchainDefinition {
	param(
		[Parameter(Mandatory)][object]$Definition,
		[string]$Context = 'definition'
	)

	if ($null -eq $Definition) { throw "$Context is null" }

	if ($Definition -is [PSCustomObject]) {
		$Definition = $Definition | ConvertTo-Json -Depth 50 | ConvertFrom-Json
	}

	$envProp = $Definition.PSObject.Properties['env']
	if (-not $envProp) { throw "$Context missing required top-level 'env' object" }
	$envObj = $envProp.Value
	Test-TlcEnvMap -EnvMap $envObj -Context "$Context.env" | Out-Null

	foreach ($p in $Definition.PSObject.Properties) {
		if ($p.Name -eq 'env') { continue }
		if ($null -eq $p.Value) { continue }
		$cfg = $p.Value
		$cfgEnv = $cfg.PSObject.Properties['env']
		if (-not $cfgEnv) { throw "$Context.$($p.Name) missing required 'env' object" }
		Test-TlcEnvMap -EnvMap $cfgEnv.Value -Context "$Context.$($p.Name).env" | Out-Null
	}

	return $true
}

function Test-TlcEnvMap {
	param(
		[Parameter(Mandatory)][object]$EnvMap,
		[string]$Context = 'env'
	)
	if ($EnvMap -isnot [PSCustomObject] -and $EnvMap -isnot [hashtable]) {
		throw "$Context must be an object/map"
	}
	$props = if ($EnvMap -is [hashtable]) { $EnvMap.Keys | ForEach-Object { @{ Name = $_; Value = $EnvMap[$_] } } } else { $EnvMap.PSObject.Properties }
	foreach ($p in $props) {
		$name = $p.Name
		$val = $p.Value
		if ($null -eq $val) { continue }
		if ($val -is [string]) { continue }
		if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
			foreach ($x in $val) {
				if ($null -eq $x) { continue }
				if ($x -isnot [string]) { throw "$Context.$name must contain only strings" }
			}
			continue
		}
		throw "$Context.$name must be a string or array of strings"
	}
	return $true
}

function Get-TlcDefinitionJson {
	$pkgRoot = Get-TlcPkgRoot
	$defPath = Join-Path $pkgRoot '.tlc'
	if (-not (Test-Path -LiteralPath $defPath -PathType Leaf)) {
		throw "toolchain definition not found: $defPath"
	}
	return (Get-Content -LiteralPath $defPath -Raw).Trim()
}

function Assert-TlcDefinitionFile {
	$pkgRoot = Get-TlcPkgRoot
	$defPath = Join-Path $pkgRoot '.tlc'
	if (-not (Test-Path -LiteralPath $defPath -PathType Leaf)) {
		throw "toolchain definition not found: $defPath"
	}
	$json = (Get-Content -LiteralPath $defPath -Raw).Trim()
	$def = $json | ConvertFrom-Json
	Test-TlcToolchainDefinition -Definition $def -Context $defPath | Out-Null
	return $json
}

