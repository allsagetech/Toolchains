<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'python'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'python'
		Repo = 'cpython'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$Version = $Tag.SubString(1)
	$Installer = 'python-installer.exe'
	Invoke-TlcWebRequest -Uri "https://www.python.org/ftp/python/$Version/python-$Version-amd64.exe" -OutFile $Installer
	New-Item -ItemType Directory -Path '\pkg' -Force | Out-Null
	$InstallDir = (Resolve-Path '\pkg').Path
	Start-Process -Wait -PassThru ".\$Installer" "/quiet AssociateFiles=0 Shortcuts=0 Include_launcher=0 InstallLauncherAllUsers=0 InstallAllUsers=0 TargetDir=$InstallDir DefaultJustForMeTargetDir=$InstallDir DefaultAllUsersTargetDir=$InstallDir"
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'python.exe' | Select-Object -Last 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		python --version
	}
}