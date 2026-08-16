<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

. "$PSScriptRoot\semantic-version.ps1"
. "$PSScriptRoot\util.ps1"
. "$PSScriptRoot\package-runtime.ps1"
. "$PSScriptRoot\package-families.ps1"
. "$PSScriptRoot\upstream-metadata.ps1"
. "$PSScriptRoot\model-catalog.ps1"

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

function Test-TlcHostIsWindows {
	return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Get-TlcDefaultWindowsRunner {
	return 'windows-2022'
}

function Get-TlcDefaultWindowsDockerRunner {
	return Get-TlcDefaultWindowsRunner
}

function Get-TlcPkgRootForRunner {
	param(
		[Parameter(Mandatory=$true)][object]$RunsOn
	)

	if (Test-TlcRunsOnUbuntu -RunsOn $RunsOn) {
		return '/mnt/toolchains-pkg'
	}
	return 'D:\pkg'
}

function Get-TlcCachePathForRunner {
	param(
		[Parameter(Mandatory=$true)][object]$RunsOn
	)

	if (Test-TlcRunsOnUbuntu -RunsOn $RunsOn) {
		return '/mnt/toolchains-pkg/cache'
	}
	return 'D:\pkg\cache'
}

function Test-TlcRunsOnUbuntu {
	param(
		[Parameter(Mandatory=$true)][object]$RunsOn
	)

	return [bool](@($RunsOn) | Where-Object { ([string]$_) -like 'ubuntu-*' } | Select-Object -First 1)
}

function Get-TlcPackageRunsOn {
	param([Parameter(Mandatory=$true)][Collections.IDictionary]$Config)
	if ($Config.RunsOn) {
		return $Config.RunsOn
	}
	return Get-TlcDefaultWindowsRunner
}

function Get-TlcPackagePublishRunsOn {
	param([Parameter(Mandatory=$true)][Collections.IDictionary]$Config)
	if ($Config.PublishRunsOn) {
		return $Config.PublishRunsOn
	}

	$runsOn = Get-TlcPackageRunsOn -Config $Config
	if (Test-TlcRunsOnUbuntu -RunsOn $runsOn) {
		return $runsOn
	}
	return Get-TlcDefaultWindowsDockerRunner
}

function Clear-TlcPackageScript {
	Remove-Item Function:\Install-TlcPackage -Force -ErrorAction SilentlyContinue
	Remove-Item Function:\Test-TlcPackageInstall -Force -ErrorAction SilentlyContinue
	Remove-Item Function:\Invoke-CustomDockerBuild -Force -ErrorAction SilentlyContinue
	Remove-Item Function:\Invoke-HuggingFaceSnapshotDownload -Force -ErrorAction SilentlyContinue
	Remove-Variable 'TlcPackageConfig' -Scope Global -Force -ErrorAction SilentlyContinue
}

function Get-TlcPackagePublicationState {
	param([Parameter(Mandatory=$true)][AllowNull()][Collections.IDictionary]$Config)
	if (-not $Config) { throw 'Package configuration is not loaded.' }
	$verifiedDownloads = if ($Config.Contains('VerifiedDownloads')) { [bool]$Config.VerifiedDownloads } else { $true }
	$descriptorEligible = if ($Config.Contains('PublishEligible')) { [bool]$Config.PublishEligible } else { $true }
	$publishEligible = $verifiedDownloads -and $descriptorEligible
	$reason = if (-not $verifiedDownloads) {
		[string]$Config.UnverifiedDownloadReason
	} elseif (-not $descriptorEligible) {
		[string]$Config.PublicationBlockReason
	} else {
		''
	}
	return [pscustomobject]@{
		VerifiedDownloads = $verifiedDownloads
		PublishEligible = $publishEligible
		QuarantineReason = $reason
	}
}

function Test-TlcPackageScript {
	Get-Item Function:\Install-TlcPackage | Out-Null
	Get-Item Function:\Test-TlcPackageInstall | Out-Null
	Get-Variable 'TlcPackageConfig' | Out-Null
	if (-not $TlcPackageConfig.Name) {
		Write-Error "toolchains: TlcPackageConfig missing name property"
	}
	Assert-TlcKindMarkerSafePackageName -Name ([string]$TlcPackageConfig.Name)
	if ($TlcPackageConfig.CanonicalName) {
		Assert-TlcKindMarkerSafePackageName -Name ([string]$TlcPackageConfig.CanonicalName)
	}
	if ($TlcPackageConfig.Platform -and [string]$TlcPackageConfig.Platform -notin @('windows/amd64', 'linux/amd64')) {
		Write-Error "toolchains: unsupported package platform: $($TlcPackageConfig.Platform)"
	}
	if ($TlcPackageConfig.Nonce -and (-not $TlcPackageConfig.Version)) {
		Write-Error "toolchains: TlcPackageConfig missing version property"
	}
	if ($TlcPackageConfig.Tier -and ($TlcPackageConfig.Tier -notin @('tooling', 'model-small', 'model-large'))) {
		Write-Error "toolchains: unsupported TlcPackageConfig tier: $($TlcPackageConfig.Tier)"
	}
	if ($TlcPackageConfig.ContainsKey('VerifiedDownloads') -and -not [bool]$TlcPackageConfig.VerifiedDownloads -and [string]::IsNullOrWhiteSpace([string]$TlcPackageConfig.UnverifiedDownloadReason)) {
		Write-Error "toolchains: $($TlcPackageConfig.Name) marks downloads unverified without an UnverifiedDownloadReason"
	}
	if ($TlcPackageConfig.ContainsKey('PublishEligible') -and -not [bool]$TlcPackageConfig.PublishEligible -and [string]::IsNullOrWhiteSpace([string]$TlcPackageConfig.PublicationBlockReason)) {
		Write-Error "toolchains: $($TlcPackageConfig.Name) blocks publication without a PublicationBlockReason"
	}
	if ($TlcPackageConfig.Vex) {
		$vexRelativePath = [string]$TlcPackageConfig.Vex
		if ([IO.Path]::IsPathRooted($vexRelativePath)) {
			Write-Error "toolchains: VEX path must be repository-relative: $vexRelativePath"
		}
		$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
		$vexRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.github/vex')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
		$vexPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $vexRelativePath))
		if (-not $vexPath.StartsWith($vexRoot, [StringComparison]::OrdinalIgnoreCase)) {
			Write-Error "toolchains: VEX path must be contained by .github/vex: $vexRelativePath"
		}
		if (-not (Test-Path -LiteralPath $vexPath -PathType Leaf)) {
			Write-Error "toolchains: VEX document does not exist: $vexRelativePath"
		}
		$vexDocument = Get-Content -LiteralPath $vexPath -Raw | ConvertFrom-Json
		if ([string]$vexDocument.'@context' -ne 'https://openvex.dev/ns/v0.2.0' -or @($vexDocument.statements).Count -eq 0) {
			Write-Error "toolchains: VEX document is not a non-empty OpenVEX 0.2 document: $vexRelativePath"
		}
	}
}

function Invoke-TlcPackageScan {
	Set-Service -Name wuauserv -StartupType Manual -Status Running
	(Get-Service wuauserv).WaitForStatus('Running')
	for ($i = 0; $i -lt 5; $i++) {
		try {
			Start-Sleep -Seconds 10.0
			Update-MpSignature
			break
		} catch {
			Write-Host "An error occurred: $($_.Exception.Message)"
		}
	}
	Start-MpScan -ScanType CustomScan -ScanPath (Resolve-Path (Get-TlcPkgRoot)).Path
	Get-MpThreatDetection
}

function Invoke-DockerBuild {
	param(
		[Parameter(Mandatory=$true)][string]$Tag,
		[Parameter(Mandatory=$true)][string]$PkgName,
		[Parameter(Mandatory=$true)][string]$PkgVersion,
		[string]$DockerfileName,
		[Parameter(Mandatory=$true)][Collections.IDictionary]$Config
	)
	$pkgRoot = Get-TlcPkgRoot
	if (-not (Test-Path $pkgRoot)) { throw "Package root does not exist: $pkgRoot" }

	$null = Assert-TlcDefinitionFile
	$defPath = Join-Path $pkgRoot '.tlc'
	$defHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $defPath).Hash.ToLowerInvariant()
	$labels = @(
		"io.allsagetech.toolchain.specVersion=1",
		"io.allsagetech.toolchain.packageName=$PkgName",
		"io.allsagetech.toolchain.packageVersion=$PkgVersion",
		"io.allsagetech.toolchain.tlcPath=/.tlc",
		"io.allsagetech.toolchain.tlcSha256=$defHash",
		"toolchain.tlcPath=/.tlc",
		"toolchain.tlcSha256=$defHash"
	)

	if (Get-Command 'Invoke-CustomDockerBuild' -ErrorAction SilentlyContinue) {
		Write-Host 'Using custom docker build'
		$Config.Name = $PkgName
		$Config.Version = $PkgVersion
		$global:LASTEXITCODE = 0
		Invoke-CustomDockerBuild $Tag $labels
		if ($LASTEXITCODE -ne 0) { throw "custom docker build failed with exit code $LASTEXITCODE for $Tag" }
		Assert-TlcBuiltImageContract -Tag $Tag -ExpectedLabels $labels
		return
	}

	$repoRoot = Split-Path -Parent $PSScriptRoot
	if (-not $DockerfileName) {
		$DockerfileName = if (Test-TlcHostIsWindows) { 'Dockerfile' } else { 'Dockerfile.linux' }
	}
	$dockerfileSrc = Join-Path $repoRoot $DockerfileName
	if (-not (Test-Path -LiteralPath $dockerfileSrc -PathType Leaf)) {
		if ($DockerfileName -ne 'Dockerfile') {
			$dockerfileSrc = Join-Path $repoRoot 'Dockerfile'
		}
		if (-not (Test-Path -LiteralPath $dockerfileSrc -PathType Leaf)) {
			throw "Dockerfile not found for package build: $DockerfileName"
		}
	}
	$dockerfileDst = Join-Path $pkgRoot 'Dockerfile'
	Copy-Item -Path $dockerfileSrc -Destination $dockerfileDst -Force
	Set-TlcPackageDockerignore -PkgRoot $pkgRoot

	$dockerArguments = @('build', '-f', $dockerfileDst, '-t', $Tag)
	foreach ($l in $labels) { $dockerArguments += @('--label', $l) }
	$dockerArguments += @($pkgRoot)

	& docker @dockerArguments
	if ($LASTEXITCODE -ne 0) {
		throw "docker build failed with exit code $LASTEXITCODE for $Tag"
	}
	Assert-TlcBuiltImageContract -Tag $Tag -ExpectedLabels $labels
}

function Assert-TlcBuiltImageContract {
	param(
		[Parameter(Mandatory=$true)][string]$Tag,
		[Parameter(Mandatory=$true)][string[]]$ExpectedLabels
	)
	$labelJson = (& docker image inspect $Tag --format '{{json .Config.Labels}}' 2>$null | Out-String).Trim()
	if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($labelJson)) {
		throw "could not inspect labels on built image $Tag"
	}
	$actualLabels = $labelJson | ConvertFrom-Json
	foreach ($label in $ExpectedLabels) {
		$separator = $label.IndexOf('=')
		$key = $label.Substring(0, $separator)
		$expected = $label.Substring($separator + 1)
		$property = $actualLabels.PSObject.Properties[$key]
		if (-not $property -or [string]$property.Value -ne $expected) {
			throw "built image $Tag is missing required label $key=$expected"
		}
	}
}

function Set-TlcPackageDockerignore {
	param(
		[Parameter(Mandatory=$true)][string]$PkgRoot
	)
	$ignorePath = Join-Path $PkgRoot '.dockerignore'
	$lines = @()
	if (Test-Path -LiteralPath $ignorePath -PathType Leaf) {
		$lines = @(Get-Content -LiteralPath $ignorePath)
	}
	foreach ($line in @('cache', 'cache/**', '_stage', '_stage/**', '**/*.partial-*', '**/*.tmp', '**/*.temp')) {
		if ($lines -notcontains $line) { $lines += $line }
	}
	[IO.File]::WriteAllLines($ignorePath, [string[]]$lines)
}


function Get-TlcDockerRepo {
	if ($env:TLC_DOCKER_REPO) {
		return $env:TLC_DOCKER_REPO
	}
	return 'allsagetech/toolchains'
}

function Test-DockerTagExists($tag) {
	$prev = $PSNativeCommandUseErrorActionPreference
	$PSNativeCommandUseErrorActionPreference = $false
	try {
		& docker manifest inspect $tag *> $null 2>$null
		return ($LASTEXITCODE -eq 0)
	} catch {
		return $false
	} finally {
		$PSNativeCommandUseErrorActionPreference = $prev
	}
}

function Test-CosignSigningEnabled {
	if ($env:TLC_COSIGN_KEY) { return $true }
	if ($env:COSIGN_KEY) { return $true }
	if ($env:TLC_COSIGN_SIGN -in '1','true','TRUE','yes','YES') { return $true }
	return $false
}

function Invoke-CosignSignImage([string]$tag) {
	if (-not (Test-CosignSigningEnabled)) { return }
	$cosign = Get-Command 'cosign' -ErrorAction SilentlyContinue
	if (-not $cosign) {
		throw 'cosign was requested but is not available on PATH'
	}
	# Use a digest reference to avoid signing a mutable tag.
	$digRef = (& docker inspect --format '{{index .RepoDigests 0}}' $tag 2>$null | Out-String).Trim()
	if (-not $digRef) {
		throw "cosign signing was requested but no immutable RepoDigest could be determined for $tag"
	}
	$cosignArguments = @('sign', '--yes')
	$key = if ($env:TLC_COSIGN_KEY) { $env:TLC_COSIGN_KEY } elseif ($env:COSIGN_KEY) { $env:COSIGN_KEY } else { $null }
	if ($key) { $cosignArguments += @('--key', $key) }
	$cosignArguments += @($digRef)

	& $cosign.Source @cosignArguments
	if ($LASTEXITCODE -ne 0) {
		throw "cosign sign failed (exit code $LASTEXITCODE) for $digRef"
	}
	Write-Host "Signed: $digRef"
}

function Invoke-DockerPush {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[Parameter(Mandatory=$true)][string]$Version,
		[Parameter(Mandatory=$true)][Collections.IDictionary]$Config
	)
	$ErrorActionPreference = 'Stop'

	$repo = Get-TlcDockerRepo
	if (-not $repo) { throw "TLC_DOCKER_REPO is empty. Set it (e.g. allsagetech/toolchains) or set secrets.DOCKER_REPO in CI." }

	$safeVer = $Version.Replace('+','_')
	$tag = "${repo}:$Name-$safeVer"

	Assert-DockerDaemonAvailable

	if (Test-DockerTagExists $tag) {
		if (Test-CosignSigningEnabled) {
			throw "image tag already exists and signing was requested; refusing to skip because the existing signature state was not proven: $tag"
		}
		Write-Host "Skip: $tag already exists"
		return
	}

	$dockerfileName = $null
	if ($Config.Contains('Dockerfile')) {
		$dockerfileName = [string]$Config.Dockerfile
	}
	Invoke-DockerBuild -Tag $tag -PkgName $Name -PkgVersion $Version -DockerfileName $dockerfileName -Config $Config

	$imageBytesText = (& docker image inspect $tag --format '{{.Size}}' 2>$null | Out-String).Trim()
	[long]$imageBytes = 0
	if ([long]::TryParse($imageBytesText, [ref]$imageBytes)) {
		$imageGiB = [math]::Round(($imageBytes / 1GB), 2)
		Write-Host "Docker image size before push: $imageBytes bytes ($imageGiB GiB)"
	}

	& docker push $tag
	if ($LASTEXITCODE -ne 0) { throw "docker push failed (exit code $LASTEXITCODE) for $tag" }
	Invoke-CosignSignImage $tag

	Write-Host "Pushed: $tag"
}

function Assert-DockerDaemonAvailable {
	$docker = Get-Command 'docker' -ErrorAction SilentlyContinue
	if (-not $docker) {
		throw 'docker CLI not found on PATH; cannot build or push toolchain container images.'
	}

	$prev = $PSNativeCommandUseErrorActionPreference
	$PSNativeCommandUseErrorActionPreference = $false
	try {
		& docker version --format '{{.Server.Version}}' *> $null
		if ($LASTEXITCODE -ne 0) {
			throw "Docker daemon is not available to this runner. Package publishing requires a runner with a working Docker service."
		}
	} finally {
		$PSNativeCommandUseErrorActionPreference = $prev
	}
}

function Invoke-TlcInit {
	if (-not $TlcPackageConfig.Nonce) {
		$tagList = Get-DockerTags (Get-TlcDockerRepo)
		$latest = [TlcSemanticVersion]::new()
		$namePart = "$($TlcPackageConfig.Name)-"
		$matcher = if ($TlcPackageConfig.Matcher) { $TlcPackageConfig.Matcher } else { "^$namePart" }
		$TlcPackageConfig.Tags = @()
		foreach ($item in $tagList.tags) {
			if ($item -match $matcher) {
				$v = [TlcSemanticVersion]::new($item.Substring($namePart.length).Replace('_', '+'))
				$TlcPackageConfig.Tags += $v
				if ($v.LaterThan($latest)) {
					$latest = $v
				}
			}
		}
		$TlcPackageConfig.Latest = $latest
	}
}

function Invoke-TlcScript($pkg) {
	return (Invoke-TlcPackageLifecycle -Path $pkg)
}

function Get-TlcPushPackagePaths {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$ChangedPath,
		[string]$RepoRoot = (Get-Location).Path
	)

	$selected = @()
	$sharedRepresentatives = @(
		'src/pkgs/websocat.ps1',
		'src/pkgs/git-linux.ps1'
	)
	$familyRepresentatives = @(
		'src/pkgs/node/node22.ps1',
		'src/pkgs/jdk/jdk17.ps1',
		'src/pkgs/kubectl.ps1',
		'src/pkgs/kubectl-linux.ps1',
		'src/pkgs/k9s.ps1',
		'src/pkgs/k9s-linux.ps1'
	)
	$sharedFiles = @(
		'src/main.ps1',
		'src/definition-file.ps1',
		'src/huggingface-download.ps1',
		'src/huggingface-image.ps1',
		'src/integrity.ps1',
		'src/model-catalog.ps1',
		'src/network.ps1',
		'src/package-runtime.ps1',
		'src/semantic-version.ps1',
		'src/upstream-metadata.ps1',
		'src/util.ps1',
		'.github/workflows/build-push.yml'
	)

	foreach ($rawPath in @($ChangedPath)) {
		if ([string]::IsNullOrWhiteSpace($rawPath)) { continue }
		$path = ([string]$rawPath -replace '\\', '/') -replace '^\./', ''

		if ($path -match '^src/pkgs/.+\.ps1$') {
			$selected += $path
		}

		if ($path -match '^src/assets/([^/]+)/') {
			$assetName = $Matches[1]
			$selected += "src/pkgs/$assetName.ps1"
			if ($assetName -eq 'kubectl') {
				$selected += 'src/pkgs/kubectl-linux.ps1'
			}
		}

		$isSharedInfrastructure = $path -in $sharedFiles -or
			$path -match '^Dockerfile(?:\..+)?$' -or
			$path -match '^\.github/scripts/.+\.ps1$'
		if ($isSharedInfrastructure) {
			$selected += $sharedRepresentatives
		}

		if ($path -eq 'src/package-families.ps1') {
			$selected += $sharedRepresentatives
			$selected += $familyRepresentatives
		}
	}

	$existing = @()
	foreach ($path in @($selected | Sort-Object -Unique)) {
		if (Test-Path -LiteralPath (Join-Path $RepoRoot $path) -PathType Leaf) {
			$existing += $path
		}
	}
	return @($existing)
}

function Save-WorkflowMatrix {
	$tagList = Get-DockerTags (Get-TlcDockerRepo)
	$pkgs = @()
	$scripts = Get-ChildItem . -Include '*.ps1' -Recurse -File |
		Where-Object { $_.FullName -match '[\\/]pkgs[\\/]' } |
		Sort-Object -Property FullName
	$repoRoot = (Get-Location).Path
	$refName = if ([string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME)) { $null } else { ($env:GITHUB_REF_NAME -replace '^.*/') }
	$descriptors = @(Read-TlcPackageDescriptors -Path @($scripts.FullName))
	foreach ($descriptor in $descriptors) {
		$script = Get-Item -LiteralPath $descriptor.Path
		Write-Output "toolchains: analyzing $($script.Name)"
		$config = $descriptor.Config
		$scriptPath = $script.FullName.Replace($repoRoot, '.')
		$runsOn = Get-TlcPackageRunsOn -Config $config
		$publishRunsOn = Get-TlcPackagePublishRunsOn -Config $config
		$tier = if ($config.Tier) { [string]$config.Tier } else { 'tooling' }
		$publicationState = Get-TlcPackagePublicationState -Config $config
		$entry = @{
			package            = $scriptPath
			runs_on            = $runsOn
			publish_runs_on    = $publishRunsOn
			tier               = $tier
			verified_downloads  = $publicationState.VerifiedDownloads
			publish_eligible    = $publicationState.PublishEligible
			quarantine_reason   = $publicationState.QuarantineReason
			unverified_download_reason = if ($publicationState.VerifiedDownloads) { '' } else { [string]$config.UnverifiedDownloadReason }
			pkg_root           = Get-TlcPkgRootForRunner -RunsOn $runsOn
			cache_path         = Get-TlcCachePathForRunner -RunsOn $runsOn
			publish_pkg_root   = Get-TlcPkgRootForRunner -RunsOn $publishRunsOn
			publish_cache_path = Get-TlcCachePathForRunner -RunsOn $publishRunsOn
		}
		$matchesRef = $false
		if ($refName) {
			$matchesRef = ("$refName.ps1" -eq $script.Name -or $refName.StartsWith("$($script.BaseName)-"))
		}
		if ($matchesRef) {
			$pkgs = ,$entry
			break
		} elseif ((-not $config.Nonce) -or ("$($config.Name)-$($config.Version)" -notin $tagList.tags)) {
			$pkgs += ,$entry
		}
	}
	$matrixPath = Join-Path (Get-Location).Path '.matrix'
	[IO.File]::WriteAllText($matrixPath, (ConvertTo-Json @{ include = $pkgs } -Depth 50 -Compress))
}
