<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'doxygen'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'doxygen'
		Repo = 'doxygen'
		TagPattern = '^Release_([0-9]+)_([0-9]+)_([0-9]+)$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$Version = $Latest.version.ToString()
	$AssetName = "doxygen-$Version.windows.x64.bin.zip"
	$downloadPage = [string](Invoke-TlcWebRequest -Uri 'https://www.doxygen.nl/download.html').Content
	$hashMatch = [regex]::Match($downloadPage, "(?is)$([regex]::Escape($AssetName))</td>\s*<td[^>]*>\s*<code>([0-9a-f]{64})</code>")
	if (-not $hashMatch.Success) { throw "Doxygen download metadata is missing SHA-256 for $AssetName" }
	$Params = @{
		AssetName = $AssetName
		AssetURL = "https://www.doxygen.nl/files/$AssetName"
		ExpectedSha256 = $hashMatch.Groups[1].Value
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'doxygen.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		doxygen --version
	}
}
