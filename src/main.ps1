<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

. "$PSScriptRoot\util.ps1"

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
	if ($TlcPackageConfig.RunsOn) {
		return $TlcPackageConfig.RunsOn
	}
	return Get-TlcDefaultWindowsRunner
}

function Get-TlcPackagePublishRunsOn {
	if ($TlcPackageConfig.PublishRunsOn) {
		return $TlcPackageConfig.PublishRunsOn
	}

	$runsOn = Get-TlcPackageRunsOn
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
	Clear-Variable 'TlcPackageConfig' -Force -ErrorAction SilentlyContinue
}

function Test-TlcPackageScript {
	Get-Item Function:\Install-TlcPackage | Out-Null
	Get-Item Function:\Test-TlcPackageInstall | Out-Null
	Get-Variable 'TlcPackageConfig' | Out-Null
	if (-not $TlcPackageConfig.Name) {
		Write-Error "toolchains: TlcPackageConfig missing name property"
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

function Invoke-DockerBuild($tag, [string]$pkgName, [string]$pkgVersion, [string]$dockerfileName) {
	$pkgRoot = Get-TlcPkgRoot
	if (-not (Test-Path $pkgRoot)) { throw "Package root does not exist: $pkgRoot" }

	$null = Assert-TlcDefinitionFile
	$defPath = Join-Path $pkgRoot '.tlc'
	$defHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $defPath).Hash.ToLowerInvariant()
	$labels = @(
		"io.allsagetech.toolchain.specVersion=1",
		"io.allsagetech.toolchain.packageName=$pkgName",
		"io.allsagetech.toolchain.packageVersion=$pkgVersion",
		"io.allsagetech.toolchain.tlcPath=/.tlc",
		"io.allsagetech.toolchain.tlcSha256=$defHash",
		"toolchain.tlcPath=/.tlc",
		"toolchain.tlcSha256=$defHash"
	)

	if (Get-Command 'Invoke-CustomDockerBuild' -ErrorAction SilentlyContinue) {
		Write-Host 'Using custom docker build'
		if (-not $global:TlcPackageConfig) { $global:TlcPackageConfig = @{} }
		if ($pkgName) { $global:TlcPackageConfig.Name = $pkgName }
		if ($pkgVersion) { $global:TlcPackageConfig.Version = $pkgVersion }
		$global:LASTEXITCODE = 0
		Invoke-CustomDockerBuild $tag $labels
		if ($LASTEXITCODE -ne 0) { throw "custom docker build failed with exit code $LASTEXITCODE for $tag" }
		Assert-TlcBuiltImageContract -Tag $tag -ExpectedLabels $labels
		return
	}

	$repoRoot = Split-Path -Parent $PSScriptRoot
	if (-not $dockerfileName) {
		$dockerfileName = if (Test-TlcHostIsWindows) { 'Dockerfile' } else { 'Dockerfile.linux' }
	}
	$dockerfileSrc = Join-Path $repoRoot $dockerfileName
	if (-not (Test-Path -LiteralPath $dockerfileSrc -PathType Leaf)) {
		if ($dockerfileName -ne 'Dockerfile') {
			$dockerfileSrc = Join-Path $repoRoot 'Dockerfile'
		}
		if (-not (Test-Path -LiteralPath $dockerfileSrc -PathType Leaf)) {
			throw "Dockerfile not found for package build: $dockerfileName"
		}
	}
	$dockerfileDst = Join-Path $pkgRoot 'Dockerfile'
	Copy-Item -Path $dockerfileSrc -Destination $dockerfileDst -Force
	Set-TlcPackageDockerignore -PkgRoot $pkgRoot

	$args = @('build', '-f', $dockerfileDst, '-t', $tag)
	foreach ($l in $labels) { $args += @('--label', $l) }
	$args += @($pkgRoot)

	& docker @args
	if ($LASTEXITCODE -ne 0) {
		throw "docker build failed with exit code $LASTEXITCODE for $tag"
	}
	Assert-TlcBuiltImageContract -Tag $tag -ExpectedLabels $labels
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
	$prev = $global:PSNativeCommandUseErrorActionPreference
	$global:PSNativeCommandUseErrorActionPreference = $false
	try {
		& docker manifest inspect $tag *> $null 2>$null
		return ($LASTEXITCODE -eq 0)
	} catch {
		return $false
	} finally {
		$global:PSNativeCommandUseErrorActionPreference = $prev
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
	$digRef = (& docker inspect --format '{{index .RepoDigests 0}}' $tag 2>$null).Trim()
	if (-not $digRef) {
		throw "cosign signing was requested but no immutable RepoDigest could be determined for $tag"
	}
	$args = @('sign', '--yes')
	$key = if ($env:TLC_COSIGN_KEY) { $env:TLC_COSIGN_KEY } elseif ($env:COSIGN_KEY) { $env:COSIGN_KEY } else { $null }
	if ($key) { $args += @('--key', $key) }
	$args += @($digRef)

	& $cosign.Source @args
	if ($LASTEXITCODE -ne 0) {
		throw "cosign sign failed (exit code $LASTEXITCODE) for $digRef"
	}
	Write-Host "Signed: $digRef"
}

function Invoke-DockerPush([string]$name, [string]$version) {
	$ErrorActionPreference = 'Stop'

	$repo = Get-TlcDockerRepo
	if (-not $repo) { throw "TLC_DOCKER_REPO is empty. Set it (e.g. allsagetech/toolchains) or set secrets.DOCKER_REPO in CI." }

	$safeVer = $version.Replace('+','_')
	$tag = "${repo}:$name-$safeVer"

	Assert-DockerDaemonAvailable

	if (Test-DockerTagExists $tag) {
		if (Test-CosignSigningEnabled) {
			throw "image tag already exists and signing was requested; refusing to skip because the existing signature state was not proven: $tag"
		}
		Write-Host "Skip: $tag already exists"
		return
	}

	$dockerfileName = $null
	if ($global:TlcPackageConfig -and $global:TlcPackageConfig.ContainsKey('Dockerfile')) {
		$dockerfileName = [string]$global:TlcPackageConfig.Dockerfile
	}
	Invoke-DockerBuild $tag $name $version $dockerfileName

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

	$prev = $global:PSNativeCommandUseErrorActionPreference
	$global:PSNativeCommandUseErrorActionPreference = $false
	try {
		& docker version --format '{{.Server.Version}}' *> $null
		if ($LASTEXITCODE -ne 0) {
			throw "Docker daemon is not available to this runner. Package publishing requires a runner with a working Docker service."
		}
	} finally {
		$global:PSNativeCommandUseErrorActionPreference = $prev
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
	$ProgressPreference = 'SilentlyContinue'
	$global:LASTEXITCODE = 0
	& $pkg
	$global:LASTEXITCODE = 0
	Invoke-TlcInit
	$global:LASTEXITCODE = 0
	Install-TlcPackage
	if ($LASTEXITCODE -ne 0) {
		throw "install package completed with exit code $LASTEXITCODE"
	}
	Write-Output "toolchains: $($TlcPackageConfig.Name) v$($TlcPackageConfig.Version) is $(if ($TlcPackageConfig.UpToDate) { 'UP-TO-DATE' } else { 'OUT-OF-DATE' })"
	if (-not $TlcPackageConfig.UpToDate) {
		$global:LASTEXITCODE = 0
		Test-TlcPackageInstall
		if ($LASTEXITCODE -ne 0) {
			throw "test package completed with exit code $LASTEXITCODE"
		}
		# Uncomment to print compressed package size
		# tar.exe -czf 'pkg.tar.gz' '\pkg'
		# Write-Host "package size $('{0:N0}' -f [math]::Floor((Get-Item 'pkg.tar.gz').Length / 1KB))KB"
		# Remove-Item 'pkg.tar.gz' -ErrorAction SilentlyContinue
	}
}

function Save-WorkflowMatrix {
	$tagList = Get-DockerTags (Get-TlcDockerRepo)
	$pkgs = @()
	$scripts = Get-ChildItem . -Include '*.ps1' -Recurse -File |
		Where-Object { $_.FullName -match '[\\/]pkgs[\\/]' } |
		Sort-Object -Property FullName
	$repoRoot = (Get-Location).Path
	$refName = if ([string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME)) { $null } else { ($env:GITHUB_REF_NAME -replace '^.*/') }
	foreach ($script in $scripts) {
		Write-Output "toolchains: analyzing $($script.Name)"
		Clear-TlcPackageScript
		& $script.FullName
		Test-TlcPackageScript
		$scriptPath = $script.FullName.Replace($repoRoot, '.')
		$runsOn = Get-TlcPackageRunsOn
		$publishRunsOn = Get-TlcPackagePublishRunsOn
		$tier = if ($TlcPackageConfig.Tier) { [string]$TlcPackageConfig.Tier } else { 'tooling' }
		$verifiedDownloads = if ($TlcPackageConfig.ContainsKey('VerifiedDownloads')) { [bool]$TlcPackageConfig.VerifiedDownloads } else { $true }
		$entry = @{
			package            = $scriptPath
			runs_on            = $runsOn
			publish_runs_on    = $publishRunsOn
			tier               = $tier
			verified_downloads  = $verifiedDownloads
			publish_eligible    = $verifiedDownloads
			unverified_download_reason = if ($verifiedDownloads) { '' } else { [string]$TlcPackageConfig.UnverifiedDownloadReason }
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
		} elseif ((-not $TlcPackageConfig.Nonce) -or ("$($TlcPackageConfig.Name)-$($TlcPackageConfig.Version)" -notin $tagList.tags)) {
			$pkgs += ,$entry
		}
	}
	Clear-TlcPackageScript
	[IO.File]::WriteAllText('.matrix', (ConvertTo-Json @{ include = $pkgs } -Depth 50 -Compress))
}
