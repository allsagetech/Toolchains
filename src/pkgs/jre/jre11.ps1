<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'jre'
	Matcher = '^jre-11\.'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'adoptium'
		Repo = 'temurin11-binaries'
		AssetPattern = '^.*jre_x64_windows_hotspot_.+?\.zip$'
		TagPattern = "^jdk-(11)\.([0-9]+)\.([0-9]+)((\.[0-9]+)?(\+[0-9]+)?)$"
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
		ToolDir = '\pkg-preinstall\x64'
	}
	Install-BuildTool @Params
	New-Item -Path '\pkg\x64' -ItemType Directory -Force -ErrorAction Ignore | Out-Null
	Move-Item "$(Get-ChildItem -Path '\pkg-preinstall\x64' -Recurse -Include 'bin' | Select-Object -First 1 | ForEach-Object { Split-Path $_ })\*" '\pkg\x64'
	$haveX86 = $false
	try {
		$Params_x86 = @{
			AssetName = $Asset.Name.Replace('_x64_', '_x86-32_')
			AssetURL  = $Asset.URL.Replace('_x64_', '_x86-32_')
			ToolDir   = '\pkg-preinstall\x86'
		}
		Install-BuildTool @Params_x86
		New-Item -Path '\pkg\x86' -ItemType Directory -Force -ErrorAction Ignore | Out-Null
		Move-Item "$(Get-ChildItem -Path '\pkg-preinstall\x86' -Recurse -Include 'bin' | Select-Object -First 1 | ForEach-Object { Split-Path $_ })\*" '\pkg\x86'
		$haveX86 = $true
	} catch {
		if ($_ -match 'Not Found') {
			Write-Host 'x86-32 JRE asset not published for this release; skipping x86 variant.'
		} else {
			throw
		}
	}

	$vars = @{
		env = @{
			java_home = (Split-Path (Get-ChildItem -Path '\pkg\x64' -Recurse -Include 'bin' | Select-Object -First 1).FullName -Parent)
			path = (Get-ChildItem -Path '\pkg\x64' -Recurse -Include 'java.exe' | Select-Object -First 1).DirectoryName
		}
		amd64 = @{
			env = @{
				java_home = (Split-Path (Get-ChildItem -Path '\pkg\x64' -Recurse -Include 'bin' | Select-Object -First 1).FullName -Parent)
				path = (Get-ChildItem -Path '\pkg\x64' -Recurse -Include 'java.exe' | Select-Object -First 1).DirectoryName
			}
		}
		x64 = @{
			env = @{
				java_home = (Split-Path (Get-ChildItem -Path '\pkg\x64' -Recurse -Include 'bin' | Select-Object -First 1).FullName -Parent)
				path = (Get-ChildItem -Path '\pkg\x64' -Recurse -Include 'java.exe' | Select-Object -First 1).DirectoryName
			}
		}
	}
	if ($haveX86) {
		$vars['x86'] = @{
			env = @{
				java_home = (Split-Path (Get-ChildItem -Path '\pkg\x86' -Recurse -Include 'bin' | Select-Object -First 1).FullName -Parent)
				path      = (Get-ChildItem -Path '\pkg\x86' -Recurse -Include 'java.exe' | Select-Object -First 1).DirectoryName
			}
		}
	}
	Write-TlcVars $vars
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		java -version
	}
	if (Test-Path '\pkg\x86') {
		Toolchain exec "$(Get-TlcPkgUri)<x86" {
			java -version
		}
	}
}
