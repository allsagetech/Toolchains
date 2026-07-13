<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'zig'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'ziglang'
		Repo = 'zig'
		TagPattern = '^([0-9]+)\.([0-9]+)\.?([0-9]+)?$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$AssetName = "zig-x86_64-windows-$Tag.zip"
	$zigIndex = Invoke-TlcRestMethod -Uri 'https://ziglang.org/download/index.json'
	$zigFile = $zigIndex.$Tag.'x86_64-windows'
	if (-not $zigFile -or [string]$zigFile.shasum -notmatch '^[0-9a-fA-F]{64}$') { throw "Zig release metadata is missing SHA-256 for $AssetName" }
	$Params = @{
		AssetName = $AssetName
		AssetURL = [string]$zigFile.tarball
		ExpectedSha256 = [string]$zigFile.shasum
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'zig.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		zig version
	}
}
