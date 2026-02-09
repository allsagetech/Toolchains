<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

. "$PSScriptRoot\util.ps1"

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

function Clear-TlcPackageScript {
	Remove-Item Function:\Install-TlcPackage -Force -ErrorAction SilentlyContinue
	Remove-Item Function:\Test-TlcPackageInstall -Force -ErrorAction SilentlyContinue
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
	Start-MpScan -ScanType CustomScan -ScanPath (Resolve-Path '\pkg').Path
	Get-MpThreatDetection
}

function Invoke-DockerBuild($tag, [string]$pkgName, [string]$pkgVersion) {
	if (Get-Command 'Invoke-CustomDockerBuild' -ErrorAction SilentlyContinue) {
		Write-Host 'Using custom docker build'
		Invoke-CustomDockerBuild $tag
		return
	}

	$pkgRoot = Get-TlcPkgRoot
	if (-not (Test-Path $pkgRoot)) { throw "Package root does not exist: $pkgRoot" }

	$null = Assert-TlcDefinitionFile
	$defPath = Join-Path $pkgRoot '.tlc'
	$defHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $defPath).Hash.ToLowerInvariant()

	$repoRoot = Split-Path -Parent $PSScriptRoot
	$dockerfileSrc = Join-Path $repoRoot 'Dockerfile'
	$dockerfileDst = Join-Path $pkgRoot 'Dockerfile'
	Copy-Item -Path $dockerfileSrc -Destination $dockerfileDst -Force

	$labels = @(
		"io.allsagetech.toolchain.specVersion=1",
		"io.allsagetech.toolchain.packageName=$pkgName",
		"io.allsagetech.toolchain.packageVersion=$pkgVersion",
		"io.allsagetech.toolchain.tlcPath=/.tlc",
		"io.allsagetech.toolchain.tlcSha256=$defHash",
		"toolchain.tlcPath=/.tlc",
		"toolchain.tlcSha256=$defHash"
	)

	$args = @('build', '-f', $dockerfileDst, '-t', $tag)
	foreach ($l in $labels) { $args += @('--label', $l) }
	$args += @($pkgRoot)

	& docker @args
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
		Write-Host "cosign not found; skipping image signing"
		return
	}
	# Use a digest reference to avoid signing a mutable tag.
	$digRef = (& docker inspect --format '{{index .RepoDigests 0}}' $tag 2>$null).Trim()
	if (-not $digRef) {
		Write-Host "cosign sign skipped; could not determine RepoDigests for $tag"
		return
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

	if (Test-DockerTagExists $tag) {
		Write-Host "Skip: $tag already exists"
		return
	}

	Invoke-DockerBuild $tag $name $version

	& docker push $tag
	if ($LASTEXITCODE -ne 0) { throw "docker push failed (exit code $LASTEXITCODE) for $tag" }
	Invoke-CosignSignImage $tag

	Write-Host "Pushed: $tag"
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
	$scripts = Get-ChildItem . -Include '*.ps1' -Recurse | Where-Object { $_.FullName -match [Regex]::Escape('\\pkgs\\') }
	foreach ($script in $scripts) {
		Write-Output "toolchains: analyzing $($script.Name)"
		Clear-TlcPackageScript
		& $script.FullName
		Test-TlcPackageScript
		if ("$($env:GITHUB_REF_NAME -replace '^.*/').ps1" -eq $script.Name -or ($env:GITHUB_REF_NAME -replace '^.*/').StartsWith("$($script.BaseName)-")) {
			$pkgs = ,$script.FullName.Replace((Get-Location), '.')
			break
		} elseif ((-not $TlcPackageConfig.Nonce) -or ("$($TlcPackageConfig.Name)-$($TlcPackageConfig.Version)" -notin $tagList.tags)) {
			$pkgs += ,$script.FullName.Replace((Get-Location), '.')
		}
	}
	Clear-TlcPackageScript
	[IO.File]::WriteAllText('.matrix', (ConvertTo-Json @{ package = $pkgs } -Depth 50 -Compress))
}
