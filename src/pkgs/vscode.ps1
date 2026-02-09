<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'vscode'
}

function global:Install-TlcPackage {
	$AssetURL = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive'
	$Response = Invoke-WebRequest $AssetURL -Method 'HEAD'
	$Version = [TlcSemanticVersion]::new($Response.Headers.'Content-Disposition', 'filename=VSCode-win32-x64-([0-9]+)\.([0-9]+)\.([0-9]+)\.zip')
	$TlcPackageConfig.UpToDate = -not $Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Params = @{
		AssetName = 'vscode.zip'
		AssetURL = $AssetURL
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'code.cmd' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		code --version
	}
}