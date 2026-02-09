<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'websocat'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'vi'
		Repo = 'websocat'
		AssetPattern = '^websocat\.x86_64.*-windows.*\.exe$'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)[^-]*$'
	}
	$Asset = Get-GitHubRelease @Params
	$TlcPackageConfig.UpToDate = -not $Asset.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Asset.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	New-Item -Path "\pkg" -ItemType Directory -Force -ErrorAction Ignore | Out-Null
	$AssetFile = "\pkg\websocat.exe"
	Write-Output "downloading $($Asset.URL) to $AssetFile"
	Invoke-TlcWebRequest -Uri $Asset.URL -OutFile $AssetFile
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'websocat.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Get-Content '\pkg\.tlc'
}