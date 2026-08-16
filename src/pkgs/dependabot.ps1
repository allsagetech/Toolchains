<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'dependabot'
	CanonicalName = 'dependabot'
	Platform = 'windows/amd64'
	GoToolchain = 'go1.26.6'
	BuildRevision = 1
	Vex = '.github/vex/dependabot.openvex.json'
}

function global:Install-TlcPackage {
	$latest = Get-GitHubTag -Owner 'dependabot' -Repo 'cli' -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
	$packageVersion = "$($latest.Version)+$($TlcPackageConfig.BuildRevision)"
	$version = [TlcSemanticVersion]::new($packageVersion)
	$TlcPackageConfig.Version = $packageVersion
	$TlcPackageConfig.UpToDate = -not $version.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }

	$packageRoot = Get-TlcPkgRoot
	New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
	Invoke-TlcVerifiedGoCommandBuild `
		-Module 'github.com/dependabot/cli' `
		-Version $latest.name `
		-Command 'github.com/dependabot/cli/cmd/dependabot' `
		-OutputPath (Get-TlcPkgPath 'dependabot.exe') `
		-GoToolchain $TlcPackageConfig.GoToolchain `
		-ForbiddenPackagePrefixes @(
			'github.com/docker/docker/pkg/authorization',
			'github.com/moby/moby/pkg/authorization',
			'github.com/moby/moby/v2/pkg/authorization'
		)

	Write-TlcVars @{ env = @{ path = $packageRoot } }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        dependabot --version
    }
}
