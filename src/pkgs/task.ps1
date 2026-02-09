<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'task'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'go-task'
		Repo = 'task'
		AssetPattern = 'task_windows_amd64\.zip'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
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
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'task.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		task --version
	}
}