<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'podman'
	GoToolchain = 'go1.26.6'
	BuildRevision = 1
	GvproxyVersion = 'v0.8.9'
	PatchedCryptoVersion = 'v0.52.0'
}

function global:Install-TlcPackage {
	$asset = Get-GitHubRelease `
		-Owner 'podman-container-tools' `
		-Repo 'podman' `
		-AssetPattern '^podman-remote-release-windows_amd64\.zip$' `
		-TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'

	$upstreamVersion = $asset.Version.ToString()
	$packageVersion = [TlcSemanticVersion]::new("$upstreamVersion+$($TlcPackageConfig.BuildRevision)")
	$TlcPackageConfig.Version = $packageVersion.ToString()
	$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }

	$installRoot = Get-TlcPkgRoot
	$podmanPath = Get-TlcPkgPath 'podman.exe'
	$gvproxyPath = Get-TlcPkgPath 'gvproxy.exe'
	$sshProxyPath = Get-TlcPkgPath 'win-sshproxy.exe'
	Invoke-TlcVerifiedGoCommandBuild `
		-Module 'go.podman.io/podman/v6' `
		-Version ([string]$asset.Identifier) `
		-Command 'go.podman.io/podman/v6/cmd/podman' `
		-OutputPath $podmanPath `
		-BuildTags 'remote exclude_graphdriver_btrfs containers_image_openpgp' `
		-GoToolchain $TlcPackageConfig.GoToolchain

	$gvproxyLdFlags = "-s -w -X github.com/containers/gvisor-tap-vsock/pkg/types.gitVersion=$($TlcPackageConfig.GvproxyVersion) -H=windowsgui"
	foreach ($helper in @(
		@{ Command = 'github.com/containers/gvisor-tap-vsock/cmd/gvproxy'; Output = $gvproxyPath },
		@{ Command = 'github.com/containers/gvisor-tap-vsock/cmd/win-sshproxy'; Output = $sshProxyPath }
	)) {
		Invoke-TlcVerifiedGoCommandBuild `
			-Module 'github.com/containers/gvisor-tap-vsock' `
			-Version $TlcPackageConfig.GvproxyVersion `
			-Command $helper.Command `
			-OutputPath $helper.Output `
			-MinimumModules @{ 'golang.org/x/crypto' = $TlcPackageConfig.PatchedCryptoVersion } `
			-GoToolchain $TlcPackageConfig.GoToolchain `
			-LdFlags $gvproxyLdFlags
	}

	foreach ($helper in @('gvproxy.exe', 'win-sshproxy.exe')) {
		if (-not (Test-Path -LiteralPath (Join-Path $installRoot $helper) -PathType Leaf)) {
			throw "$helper was not found beside podman.exe"
		}
	}

	Write-TlcVars @{ env = @{ path = $installRoot } }
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		podman --version
		podman machine --help | Out-Null
	}
}
