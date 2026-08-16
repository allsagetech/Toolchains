<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'nasm'
}

function global:Install-TlcPackage {
	# Independently reviewed checksum from microsoft/winget-pkgs commit
	# 95cfd2205ca56091856af003d60b164bf3c00c06. The installer is fetched
	# from NASM's official HTTPS origin and extracted without executing it.
	$Version = '3.2.0'
	$AssetVersion = '3.02'
	$ExpectedSha256 = '0ddb40310861eb29f4d649feb9466779982a2d251c0db2b9cf0d21cf591171f3'
	$Upstream = [TlcSemanticVersion]::new($Version)
	$TlcPackageConfig.UpToDate = -not $Upstream.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Version
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$AssetName = "nasm-$AssetVersion-installer-x64.exe"
	$AssetURL = "https://www.nasm.us/pub/nasm/releasebuilds/$AssetVersion/win64/$AssetName"
	$AssetPath = Get-TlcStagingPath $AssetName
	$InstallRoot = Get-TlcPkgPath "nasm-$Version"
	try {
		Invoke-TlcWebRequest -Uri $AssetURL -OutFile $AssetPath -ExpectedSha256 $ExpectedSha256
		New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
		$SevenZip = Get-Tlc7ZipExecutable
		& $SevenZip x -y "-o$InstallRoot" $AssetPath | Out-Null
		if ($LASTEXITCODE -ne 0) { throw "Could not extract the verified NASM installer: $AssetName" }
	} finally {
		Remove-Item -LiteralPath $AssetPath -Force -ErrorAction SilentlyContinue
	}
	$Nasm = Get-ChildItem -Path $InstallRoot -Recurse -Include 'nasm.exe' -File | Select-Object -First 1
	if (-not $Nasm) { throw "nasm.exe was not found after extracting $AssetName" }
	Write-TlcVars @{
		env = @{
			path = $Nasm.DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) { nasm -v }
}
