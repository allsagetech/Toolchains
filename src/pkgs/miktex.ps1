<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'MiKTeX'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'MiKTeX'
		Repo = 'miktex'
		TagPattern = '^([0-9]+)\.([0-9]+)\.?([0-9]+)?$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$AssetName = 'miktexsetup-x64.zip'
	$PackageSet = 'basic'
	$ToolDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath("\pkg")
	$Asset = "$env:Temp/$AssetName"
	Invoke-TlcWebRequest -Uri "https://miktex.org/download/win/$AssetName" -OutFile $Asset
	Expand-Archive $Asset 'miktexsetup'
	& 'miktexsetup\miktexsetup_standalone.exe' --verbose "--package-set=$PackageSet" download
	& 'miktexsetup\miktexsetup_standalone.exe' --verbose "--package-set=$PackageSet" "--portable=$ToolDir" install
	[System.IO.File]::WriteAllText("$ToolDir\texmfs\config\miktex\config\issues.json", '[]')
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path $ToolDir -Recurse -Include 'latex.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		latex -version
	}
}