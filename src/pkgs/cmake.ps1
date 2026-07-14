<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'cmake'
}

function global:Install-TlcPackage {
	$asset = Get-GitHubRelease -Owner 'Kitware' -Repo 'CMake' `
		-AssetPattern '^cmake-[0-9]+\.[0-9]+\.[0-9]+-windows-x86_64\.zip$' `
		-TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
	$Version = $asset.Version
	$TlcPackageConfig.UpToDate = -not $Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Version.ToString()
	if ($TlcPackageConfig.UpToDate) { return }

	$versionString = $Version.ToString()
	$checksumUrl = $asset.URL.Replace($asset.Name, "cmake-$versionString-SHA-256.txt")
	$expectedSha256 = if ($asset.ExpectedSha256) { $asset.ExpectedSha256 } else { Get-TlcRemoteSha256 -ChecksumUri $checksumUrl -AssetName $asset.Name }
	Install-BuildTool -AssetName $asset.Name -AssetURL $asset.URL -ExpectedSha256 $expectedSha256
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'cmake.exe' | Select-Object -First 1).DirectoryName
		}
	}
}
function global:Test-TlcPackageInstall {
	Get-Content (Get-TlcPkgPath '.tlc')
}
