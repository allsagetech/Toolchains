<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'k3d'
	CanonicalName = 'k3d'
	Platform = 'windows/amd64'
	GoToolchain = 'go1.26.6'
	Vex = '.github/vex/k3d.openvex.json'
}

function global:Install-TlcPackage {
	$asset = Get-GitHubRelease `
		-Owner 'k3d-io' `
		-Repo 'k3d' `
		-AssetPattern '^k3d-windows-amd64\.exe$' `
		-TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'

	$TlcPackageConfig.Version = $asset.Version.ToString()
	$TlcPackageConfig.UpToDate = -not $asset.Version.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }

	$pkgRoot = Get-TlcPkgRoot
	New-Item -Path $pkgRoot -ItemType Directory -Force -ErrorAction Ignore | Out-Null
	$sourceRoot = Join-Path ([IO.Path]::GetTempPath()) "tlc-k3d-$([guid]::NewGuid().ToString('n'))"
	$locationPushed = $false
	$previous = @{
		CGO_ENABLED = $env:CGO_ENABLED
		GOFLAGS = $env:GOFLAGS
		GOSUMDB = $env:GOSUMDB
		GOTOOLCHAIN = $env:GOTOOLCHAIN
		GOWORK = $env:GOWORK
	}
	try {
		$env:CGO_ENABLED = '0'
		$env:GOFLAGS = '-mod=mod'
		$env:GOSUMDB = 'sum.golang.org'
		$env:GOTOOLCHAIN = $TlcPackageConfig.GoToolchain
		$env:GOWORK = 'off'
		$go = Get-TlcApplicationPath -Name 'go'
		$module = "github.com/k3d-io/k3d/v5@v$($TlcPackageConfig.Version)"
		$downloadJson = Invoke-TlcNativeCommand -FilePath $go -ArgumentList @('mod', 'download', '-json', $module) `
			-FailureMessage 'verified k3d source download failed' -PassThru
		$download = $downloadJson | ConvertFrom-Json
		if (-not $download.Dir -or -not (Test-Path -LiteralPath $download.Dir -PathType Container)) { throw 'verified k3d module source was not available' }
		Copy-Item -LiteralPath $download.Dir -Destination $sourceRoot -Recurse -Force
		Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
		Push-Location $sourceRoot
		$locationPushed = $true

		Invoke-TlcNativeCommand -FilePath $go -ArgumentList @(
			'get', 'golang.org/x/net@v0.56.0', 'golang.org/x/text@v0.39.0', 'google.golang.org/grpc@v1.82.1'
		) -FailureMessage 'k3d dependency patch failed'

		$dependencyText = Invoke-TlcNativeCommand -FilePath $go -ArgumentList @('list', '-deps', '.') `
			-FailureMessage 'k3d dependency verification failed' -PassThru
		$dependencies = @($dependencyText -split '\r?\n')
		$forbidden = @($dependencies | Where-Object { $_ -eq 'github.com/docker/cli/cli-plugins/manager' -or $_ -like 'github.com/docker/docker/daemon*' })
		if ($forbidden.Count -gt 0) { throw "k3d unexpectedly links VEX-excluded code: $($forbidden -join ', ')" }

		$versionSource = [IO.File]::ReadAllText((Join-Path $sourceRoot 'version/version.go'))
		if ($versionSource -notmatch 'var K3sVersion = "([^"]+)"') { throw 'could not determine the k3s version embedded by k3d' }
		$k3sVersion = $Matches[1]
		$ldflags = "-s -w -X github.com/k3d-io/k3d/v5/version.Version=v$($TlcPackageConfig.Version) -X github.com/k3d-io/k3d/v5/version.K3sVersion=$k3sVersion"
		Invoke-TlcNativeCommand -FilePath $go `
			-ArgumentList @('build', '-trimpath', '-ldflags', $ldflags, '-o', (Get-TlcPkgPath 'k3d.exe'), '.') `
			-FailureMessage 'verified k3d source build failed'
	} finally {
		if ($locationPushed) { Pop-Location }
		foreach ($name in $previous.Keys) {
			if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue }
			else { Set-Item -LiteralPath "env:$name" -Value $previous[$name] }
		}
		if (Test-Path -LiteralPath $sourceRoot) { Remove-Item -LiteralPath $sourceRoot -Recurse -Force }
	}
	if (-not (Test-Path -LiteralPath (Get-TlcPkgPath 'k3d.exe') -PathType Leaf)) { throw 'k3d source build did not produce k3d.exe' }
	Write-TlcVars @{ env = @{ path = (Get-TlcPkgRoot) } }
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		k3d version
	}
}
