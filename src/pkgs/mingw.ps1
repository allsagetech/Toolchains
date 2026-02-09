<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'mingw'
}

function global:Install-TlcPackage {
	$sevenZipRoot = Join-Path $env:TEMP 'tlc-7za'
	$sevenZipExe  = Join-Path $sevenZipRoot '7za.exe'
	if (-not (Test-Path $sevenZipExe)) {
		$zip = Join-Path $env:TEMP '7za920.zip'
		Invoke-TlcWebRequest -Uri 'https://www.7-zip.org/a/7za920.zip' -OutFile $zip
		if (Test-Path $sevenZipRoot) { Remove-Item -Recurse -Force $sevenZipRoot }
		New-Item -ItemType Directory -Path $sevenZipRoot -Force | Out-Null
		Expand-Archive -Path $zip -DestinationPath $sevenZipRoot -Force
	}
	$Params = @{
		Owner = 'niXman'
		Repo = 'mingw-builds-binaries'
		AssetPattern = 'x86_64-.+-win32(?:-.+)?-ucrt-.+\.7z'
		TagPattern = '^([0-9]+)\.([0-9]+)\.([0-9]+)-[^-]+(?:-rev([0-9]+))?$'
	}
	$Asset = Get-GitHubRelease @Params
	$TlcPackageConfig.UpToDate = -not $Asset.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Asset.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$mingw = "$env:Temp\$($Asset.Name)"
	Invoke-TlcWebRequest -Uri $Asset.URL -OutFile $mingw
	& $sevenZipExe x -o'\pkg\x64' $mingw | Out-Null
	$Params.AssetPattern = 'i686-.+-win32(?:-.+)?-ucrt-.+\.7z'
	$Asset = Get-GitHubRelease @Params
	$mingw = "$env:Temp\$($Asset.Name)"
	Invoke-TlcWebRequest -Uri $Asset.URL -OutFile $mingw
	& $sevenZipExe x -o'\pkg\x86' $mingw | Out-Null
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg\x64' -Recurse -Include 'gcc.exe' | Select-Object -First 1).DirectoryName
		}
		amd64 = @{
			env = @{
				path = (Get-ChildItem -Path '\pkg\x64' -Recurse -Include 'gcc.exe' | Select-Object -First 1).DirectoryName
			}
		}
		x64 = @{
			env = @{
				path = (Get-ChildItem -Path '\pkg\x64' -Recurse -Include 'gcc.exe' | Select-Object -First 1).DirectoryName
			}
		}
		x86 = @{
			env = @{
				path = (Get-ChildItem -Path '\pkg\x86' -Recurse -Include 'gcc.exe' | Select-Object -First 1).DirectoryName
			}
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		gcc --version
	}
}