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
	$sevenZipRoot = Join-Path $env:TEMP 'tlc-7zip'
	$sevenZipExe  = Join-Path $sevenZipRoot '7z.exe'
	if (-not (Test-Path $sevenZipExe)) {
		$installer = Join-Path $env:TEMP '7z-x64.exe'
		Invoke-TlcWebRequest -Uri 'https://www.7-zip.org/a/7z2501-x64.exe' -OutFile $installer
		if (Test-Path $sevenZipRoot) { Remove-Item -Recurse -Force $sevenZipRoot }
		New-Item -ItemType Directory -Path $sevenZipRoot -Force | Out-Null
		$proc = Start-Process -FilePath $installer -ArgumentList @('/S', "/D=$sevenZipRoot") -PassThru -Wait
		if ($proc.ExitCode -ne 0) { throw "7-zip bootstrap installer failed with exit code $($proc.ExitCode)" }
		if (-not (Test-Path $sevenZipExe)) {
			$found = (Get-ChildItem -Path $sevenZipRoot -Recurse -Include '7z.exe' | Select-Object -First 1)
			if ($found) { $sevenZipExe = $found.FullName } else { throw 'Failed to bootstrap 7z.exe' }
		}
	}
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
	New-Item -ItemType Directory -Path '\app' -Force | Out-Null
	New-Item -ItemType Directory -Path '\pkg' -Force | Out-Null
	& $sevenZipExe x -o'\app' $obby | Out-Null
	& $sevenZipExe x -o'\pkg' '\app\$PLUGINSDIR\app-64.7z' | Out-Null
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'obsidian.exe' | Select-Object -First 1).DirectoryName
		}
	}
}


function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		Get-Command obsidian
	}
}
