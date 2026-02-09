<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'sonar-scanner'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'SonarSource'
		Repo = 'sonar-scanner-cli'
		TagPattern = '^([0-9]+)\.([0-9]+)\.?([0-9]+)?(\.[0-9]+)?$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$Params = @{
		AssetName = 'sonar-scanner.zip'
		AssetURL = "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-$Tag.zip"
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'sonar-scanner' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		sonar-scanner --version
	}
}
