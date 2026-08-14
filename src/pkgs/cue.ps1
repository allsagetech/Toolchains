<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'cue'
	GoToolchain = 'go1.26.6'
	BuildRevision = 1
	PatchedTextVersion = 'v0.39.0'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'cue-lang'
		Repo = 'cue'
		AssetPattern = '^cue_v.+_windows_amd64\.zip$'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
	}
	$Asset = Get-GitHubRelease @Params
	$upstreamVersion = $Asset.Version.ToString()
	$packageVersion = [TlcSemanticVersion]::new("$upstreamVersion+$($TlcPackageConfig.BuildRevision)")
	$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $packageVersion.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}

	$outputPath = Get-TlcPkgPath 'cue.exe'
	Invoke-TlcVerifiedGoCommandBuild `
		-Module 'cuelang.org/go' `
		-Version ([string]$Asset.Identifier) `
		-Command 'cuelang.org/go/cmd/cue' `
		-OutputPath $outputPath `
		-MinimumModules @{ 'golang.org/x/text' = $TlcPackageConfig.PatchedTextVersion } `
		-GoToolchain $TlcPackageConfig.GoToolchain

	Write-TlcVars @{
		env = @{
			path = (Get-TlcPkgRoot)
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		cue version
	}
}
