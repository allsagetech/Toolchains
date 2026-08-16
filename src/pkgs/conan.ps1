<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'conan'
	BuildRevision = 1
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'conan-io'
		Repo = 'conan'
		AssetPattern = '^conan-.+?-windows-x86_64.zip$'
		TagPattern = '^([0-9]+)\.([0-9]+)\.([0-9]+)$'
	}
	$Asset = Get-GitHubRelease @Params
	$packageVersion = [TlcSemanticVersion]::new("$($Asset.Version)+$($TlcPackageConfig.BuildRevision)")
	$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $packageVersion.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Params = @{
		AssetName = $Asset.Name
		AssetURL = $Asset.URL
	}
	Install-BuildTool @Params
	$staleSetuptoolsMetadata = @(Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Directory -Filter 'setuptools-*.dist-info')
	foreach ($metadataDirectory in $staleSetuptoolsMetadata) {
		Remove-Item -LiteralPath $metadataDirectory.FullName -Recurse -Force
	}
	if (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Directory -Filter 'setuptools-*.dist-info' | Select-Object -First 1) {
		throw 'Stale setuptools distribution metadata remained in the Conan package.'
	}
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'conan.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		conan --version
		conan --help
	}
}
