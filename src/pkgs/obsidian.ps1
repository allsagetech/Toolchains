<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'obsidian'
}

function global:Install-TlcPackage {
$Params = @{
		Owner        = 'obsidianmd'
		Repo         = 'obsidian-releases'
		AssetPattern = '^Obsidian-([0-9]+)\.([0-9]+)\.([0-9]+)\.exe$'
		TagPattern   = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
	}
	$Asset = Get-GitHubRelease @Params
	$TlcPackageConfig.UpToDate = -not $Asset.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Asset.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Params = @{
		AssetName = $Asset.Name
		AssetURL = $Asset.URL
	}
	Write-Host "URL = $($Asset.URL)"
	$obby = "obsidian.exe"
	Invoke-TlcWebRequest -Uri "$($Asset.URL)" -OutFile $obby
	$sevenZipExe = Get-Tlc7ZipExecutable
	$appRoot = Get-TlcStagingPath 'obsidian-app'
	if (Test-Path -LiteralPath $appRoot) { Remove-Item -LiteralPath $appRoot -Recurse -Force }
	New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
	New-Item -ItemType Directory -Path (Get-TlcPkgRoot) -Force | Out-Null
	& $sevenZipExe x ("-o{0}" -f $appRoot) $obby | Out-Null
	& $sevenZipExe x ("-o{0}" -f (Get-TlcPkgRoot)) (Join-Path $appRoot '$PLUGINSDIR\app-64.7z') | Out-Null
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'obsidian.exe' | Select-Object -First 1).DirectoryName
		}
	}
}


function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		Get-Command obsidian
	}
}
