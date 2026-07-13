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
	$metadata = Invoke-TlcRestMethod -Uri 'https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest'
	$AssetURL = [string]$metadata.url
	$expectedSha256 = [string]$metadata.sha256hash
	if (-not $AssetURL -or $expectedSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'VS Code update metadata is missing the archive URL or SHA-256.' }
	$Version = [TlcSemanticVersion]::new([string]$metadata.productVersion)
	$TlcPackageConfig.UpToDate = -not $Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Params = @{
		AssetName = 'vscode.zip'
		AssetURL = $AssetURL
		ExpectedSha256 = $expectedSha256
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'code.cmd' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		code --version
	}
}
