<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'zstd'
}

function global:Install-TlcPackage {
	# Independently reviewed checksum from microsoft/winget-pkgs commit
	# 174e50f32620b225d61f4013c1fd7331457a4920. The archive is fetched
	# from Meta's official GitHub release and any byte change fails closed.
	$Version = '1.5.7'
	$ExpectedSha256 = 'acb4e8111511749dc7a3ebedca9b04190e37a17afeb73f55d4425dbf0b90fad9'
	$Upstream = [TlcSemanticVersion]::new($Version)
	$TlcPackageConfig.UpToDate = -not $Upstream.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Version
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Params = @{
		AssetName = "zstd-v$Version-win64.zip"
		AssetURL = "https://github.com/facebook/zstd/releases/download/v$Version/zstd-v$Version-win64.zip"
		ExpectedSha256 = $ExpectedSha256
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'zstd.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	toolchain exec (Get-TlcPkgUri) {
		zstd --version
	}
}
