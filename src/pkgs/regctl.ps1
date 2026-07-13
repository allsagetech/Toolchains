<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'regctl'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'regclient'
		Repo = 'regclient'
		AssetPattern = 'regctl-windows-amd64.exe'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.?([0-9]+)?$'
	}
	$Asset = Get-GitHubRelease @Params
	$TlcPackageConfig.UpToDate = -not $Asset.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Asset.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	New-Item -Path (Get-TlcPkgRoot) -ItemType Directory -Force -ErrorAction Ignore | Out-Null
	Invoke-TlcWebRequest -Uri $Asset.URL -OutFile (Get-TlcPkgPath 'regctl.exe')
	Invoke-TlcWebRequest -Uri $Asset.URL.Replace('regctl-', 'regbot-') -OutFile (Get-TlcPkgPath 'regbot.exe')
	Invoke-TlcWebRequest -Uri $Asset.URL.Replace('regctl-', 'regsync-') -OutFile (Get-TlcPkgPath 'regsync.exe')
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'regctl.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		regctl version
		regbot version
		regsync version
	}
}