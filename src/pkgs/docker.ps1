<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

$global:TlcPackageConfig = @{
	Name = 'docker'
}

function global:Install-TlcPackage {
	# Rebuild both executables from the exact upstream 29.7.2 commits with the
	# first patched Go toolchain. The official Windows bundle embeds Go 1.26.5
	# in docker.exe and dockerd.exe, and the publication scan rejects both.
	$UpstreamVersion = '29.7.2'
	$BuildRevision = 1
	$UpstreamCommit = 'a7dcaa6fdb6ed04aacbfdc76357fdae01605609e'
	$UpstreamCommitDate = '2026-08-05T17:34:15Z'
	$ExpectedSha256 = '3cce08f4de9d3a34a2afd9080e4e6aa37c39c857243396979847f03d6e6e86c5'
	$MobyCommit = '6a43e3d5afddf4111da0f864bbc7cae5d7e95001'
	$MobyCommitDate = '2026-08-05T18:24:27Z'
	$MobyExpectedSha256 = '075b3fbb7741f40c46f996747ab75853b423b69ac4c12af1adb618a7fc8d0a02'
	$GoToolchain = 'go1.26.6'
	$GoWinresVersion = 'v0.3.3'
	$PackageVersion = "$UpstreamVersion+$BuildRevision"
	$upstream = [TlcSemanticVersion]::new($PackageVersion)
	$TlcPackageConfig.Version = $PackageVersion
	$TlcPackageConfig.UpToDate = -not $upstream.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }

	$packageRoot = Get-TlcPkgRoot
	$cliArchivePath = Get-TlcStagingPath "docker-cli-$UpstreamCommit.zip"
	$cliSourceRoot = Get-TlcStagingPath "docker-cli-$UpstreamCommit"
	$cliSourceUrl = "https://github.com/docker/cli/archive/$UpstreamCommit.zip"
	$mobyArchivePath = Get-TlcStagingPath "moby-$MobyCommit.zip"
	$mobySourceRoot = Get-TlcStagingPath "moby-$MobyCommit"
	$mobySourceUrl = "https://github.com/moby/moby/archive/$MobyCommit.zip"
	$outputRoot = Get-TlcStagingPath "docker-build-$PackageVersion"
	$goToolsRoot = Get-TlcStagingPath "docker-go-tools-$PackageVersion"
	$dockerBuild = Join-Path $outputRoot 'docker.exe'
	$dockerdBuild = Join-Path $outputRoot 'dockerd.exe'
	$locationPushed = $false
	$previous = @{}
	foreach ($name in @('CGO_ENABLED', 'GOBIN', 'GO111MODULE', 'GOFLAGS', 'GONOSUMDB', 'GOPATH', 'GOPRIVATE', 'GOPROXY', 'GOSUMDB', 'GOTOOLCHAIN', 'GOWORK', 'PATH')) {
		$previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
	}
	try {
		foreach ($path in @($cliSourceRoot, $mobySourceRoot, $outputRoot, $goToolsRoot)) {
			if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
		}
		New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

		$env:CGO_ENABLED = '0'
		$env:GO111MODULE = 'on'
		$env:GOFLAGS = '-mod=vendor'
		$env:GONOSUMDB = $null
		$env:GOPRIVATE = $null
		$env:GOPROXY = 'https://proxy.golang.org,direct'
		$env:GOSUMDB = 'sum.golang.org'
		$env:GOTOOLCHAIN = $GoToolchain
		$env:GOWORK = 'off'
		$go = Get-TlcApplicationPath -Name 'go'

		Invoke-TlcWebRequest -Uri $cliSourceUrl -OutFile $cliArchivePath -ExpectedSha256 $ExpectedSha256 | Out-Null
		Expand-Archive -LiteralPath $cliArchivePath -DestinationPath $cliSourceRoot -Force
		$cliSource = Get-ChildItem -LiteralPath $cliSourceRoot -Directory | Select-Object -First 1
		if (-not $cliSource) { throw 'Docker CLI source archive did not contain a source directory.' }
		Copy-Item -LiteralPath (Join-Path $cliSource.FullName 'vendor.mod') -Destination (Join-Path $cliSource.FullName 'go.mod') -Force
		Copy-Item -LiteralPath (Join-Path $cliSource.FullName 'vendor.sum') -Destination (Join-Path $cliSource.FullName 'go.sum') -Force
		$cliLdflags = "-s -w -X github.com/docker/cli/cli/version.GitCommit=$UpstreamCommit -X github.com/docker/cli/cli/version.BuildTime=$UpstreamCommitDate -X github.com/docker/cli/cli/version.Version=$UpstreamVersion"
		Push-Location $cliSource.FullName
		$locationPushed = $true
		Invoke-TlcNativeCommand -FilePath $go `
			-ArgumentList @('build', '-buildvcs=false', '-trimpath', '-tags', 'grpcnotrace', '-ldflags', $cliLdflags, '-o', $dockerBuild, './cmd/docker') `
			-FailureMessage 'Docker CLI source build failed'
		if (-not (Test-Path -LiteralPath $dockerBuild -PathType Leaf)) { throw 'Docker CLI source build did not produce docker.exe.' }
		Pop-Location
		$locationPushed = $false

		Invoke-TlcWebRequest -Uri $mobySourceUrl -OutFile $mobyArchivePath -ExpectedSha256 $MobyExpectedSha256 | Out-Null
		Expand-Archive -LiteralPath $mobyArchivePath -DestinationPath $mobySourceRoot -Force
		$mobySource = Get-ChildItem -LiteralPath $mobySourceRoot -Directory | Select-Object -First 1
		if (-not $mobySource) { throw 'Moby source archive did not contain a source directory.' }

		New-Item -ItemType Directory -Path $goToolsRoot -Force | Out-Null
		$env:GOFLAGS = $null
		$env:GOBIN = $goToolsRoot
		if (-not $env:GOPATH) {
			$env:GOPATH = (Invoke-TlcNativeCommand -FilePath $go -ArgumentList @('env', 'GOPATH') `
				-FailureMessage 'Could not resolve GOPATH for the Docker resource build' -PassThru).Trim()
			if (-not $env:GOPATH) { throw 'Could not resolve GOPATH for the Docker resource build.' }
		}
		Invoke-TlcNativeCommand -FilePath $go -ArgumentList @('install', "github.com/tc-hib/go-winres@$GoWinresVersion") `
			-FailureMessage "go-winres $GoWinresVersion installation failed"
		$goWinres = Join-Path $goToolsRoot 'go-winres.exe'
		$toolMetadata = Invoke-TlcNativeCommand -FilePath $go -ArgumentList @('version', '-m', $goWinres) `
			-FailureMessage 'Could not inspect go-winres build tool provenance' -PassThru
		if ($toolMetadata -notmatch "(?m)^\s*mod\s+github\.com/tc-hib/go-winres\s+$([regex]::Escape($GoWinresVersion))\s") {
			throw "go-winres build tool provenance did not resolve to $GoWinresVersion."
		}
		$env:PATH = "$goToolsRoot;$($previous['PATH'])"
		$env:GOFLAGS = '-mod=vendor'
		Push-Location $mobySource.FullName
		$locationPushed = $true
		$pwsh = Get-TlcApplicationPath -Name 'pwsh'
		Invoke-TlcNativeCommand -FilePath $pwsh -ArgumentList @(
			'-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $mobySource.FullName 'hack\make\.go-autogen.ps1'),
			'-CommitString', $MobyCommit, '-DockerVersion', $UpstreamVersion,
			'-Platform', 'Docker Engine - Community', '-Product', 'Docker Engine - Community',
			'-DefaultProductLicense', 'Community Engine', '-PackagerName', 'Docker, Inc.'
		) -FailureMessage 'Moby Windows resource generation failed'
		$daemonLdflags = "-s -w -linkmode=internal -X github.com/moby/moby/v2/dockerversion.Version=$UpstreamVersion -X github.com/moby/moby/v2/dockerversion.GitCommit=$MobyCommit -X github.com/moby/moby/v2/dockerversion.BuildTime=$MobyCommitDate -X 'github.com/moby/moby/v2/dockerversion.PlatformName=Docker Engine - Community' -X 'github.com/moby/moby/v2/dockerversion.ProductName=Docker Engine - Community' -X 'github.com/moby/moby/v2/dockerversion.DefaultProductLicense=Community Engine'"
		Invoke-TlcNativeCommand -FilePath $go `
			-ArgumentList @('build', '-buildvcs=false', '-trimpath', '-tags', 'daemon', '-ldflags', $daemonLdflags, '-o', $dockerdBuild, './cmd/dockerd') `
			-FailureMessage 'Docker daemon source build failed'
		if (-not (Test-Path -LiteralPath $dockerdBuild -PathType Leaf)) { throw 'Docker daemon source build did not produce dockerd.exe.' }
		Pop-Location
		$locationPushed = $false

		foreach ($binary in @($dockerBuild, $dockerdBuild)) {
			$buildMetadata = Invoke-TlcNativeCommand -FilePath $go -ArgumentList @('version', '-m', $binary) `
				-FailureMessage "Could not inspect $([IO.Path]::GetFileName($binary)) build metadata" -PassThru
			if ($buildMetadata -notmatch "(?m)^$([regex]::Escape($binary)):\s+$([regex]::Escape($GoToolchain))\s*$") {
				throw "$([IO.Path]::GetFileName($binary)) was not built with required toolchain $GoToolchain."
			}
			$versionText = Invoke-TlcNativeCommand -FilePath $binary -ArgumentList @('--version') `
				-FailureMessage "$([IO.Path]::GetFileName($binary)) version check failed" -PassThru
			if ($versionText -notmatch "Docker version $([regex]::Escape($UpstreamVersion)),") {
				throw "$([IO.Path]::GetFileName($binary)) did not report Docker $UpstreamVersion."
			}
		}

		New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
		Copy-Item -LiteralPath $dockerBuild -Destination (Get-TlcPkgPath 'docker.exe') -Force
		Copy-Item -LiteralPath $dockerdBuild -Destination (Get-TlcPkgPath 'dockerd.exe') -Force
	} finally {
		if ($locationPushed) { Pop-Location }
		foreach ($name in $previous.Keys) {
			if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue }
			else { Set-Item -LiteralPath "env:$name" -Value $previous[$name] }
		}
		foreach ($path in @($cliArchivePath, $mobyArchivePath)) {
			Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
		}
		foreach ($path in @($cliSourceRoot, $mobySourceRoot, $outputRoot, $goToolsRoot)) {
			Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	Write-TlcVars @{ env = @{ path = $packageRoot } }
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		docker --version
		dockerd --version
	}
}
