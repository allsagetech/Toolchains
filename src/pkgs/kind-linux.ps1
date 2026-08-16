<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'kind-linux'
	CanonicalName = 'kind'
	Platform = 'linux/amd64'
	RunsOn = 'ubuntu-22.04'
	GoToolchain = 'go1.26.6'
}

function global:Install-TlcPackage {
	$asset = Get-GitHubRelease `
		-Owner 'kubernetes-sigs' `
		-Repo 'kind' `
		-AssetPattern '^kind-linux-amd64$' `
		-TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'

	$TlcPackageConfig.Version = $asset.Version.ToString()
	$TlcPackageConfig.UpToDate = -not $asset.Version.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }

	$pkgRoot = Get-TlcPkgRoot
	New-Item -Path $pkgRoot -ItemType Directory -Force -ErrorAction Ignore | Out-Null
	$previous = @{
		CGO_ENABLED = $env:CGO_ENABLED
		GOBIN = $env:GOBIN
		GOFLAGS = $env:GOFLAGS
		GOSUMDB = $env:GOSUMDB
		GOTOOLCHAIN = $env:GOTOOLCHAIN
		GOWORK = $env:GOWORK
	}
	try {
		$env:CGO_ENABLED = '0'
		$env:GOBIN = $pkgRoot
		$env:GOFLAGS = $null
		$env:GOSUMDB = 'sum.golang.org'
		$env:GOTOOLCHAIN = $TlcPackageConfig.GoToolchain
		$env:GOWORK = 'off'
		$go = Get-TlcApplicationPath -Name 'go'
		Invoke-TlcNativeCommand -FilePath $go -ArgumentList @('install', "sigs.k8s.io/kind@v$($TlcPackageConfig.Version)") `
			-FailureMessage 'verified kind source build failed'
	} finally {
		foreach ($name in $previous.Keys) {
			if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue }
			else { Set-Item -LiteralPath "env:$name" -Value $previous[$name] }
		}
	}
	$executable = Get-TlcPkgPath 'kind'
	if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'kind source build did not produce kind' }
	& chmod '+x' $executable
	if ($LASTEXITCODE -ne 0) { throw 'failed to mark kind executable' }
	Write-TlcVars @{ env = @{ path = (Get-TlcPkgRoot) } }
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		kind version
	}
}
