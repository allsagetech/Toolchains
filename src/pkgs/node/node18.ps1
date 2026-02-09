<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

# End-of-Life was 2025-04-30 (Node.js 18 "Hydrogen"). See https://nodejs.org/en/about/releases/
# Note: This package is provided for compatibility, but Node.js 18 is EOL and receives no security updates.
$global:TlcPackageConfig = @{
	Name = 'node'
	Matcher = '^node-18\.'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'nodejs'
		Repo = 'node'
		TagPattern = '^v(18)\.([0-9]+)\.([0-9]+)$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$AssetName = "node-$Tag-win-x64.zip"
	$Params = @{
		AssetName = $AssetName
		AssetURL = "https://nodejs.org/dist/$Tag/$AssetName"
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'node.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		node --version
	}
}
