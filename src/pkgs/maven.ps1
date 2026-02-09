<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'maven'
}

function global:Install-TlcPackage {
	$Version = $null
	$PkgInfo = $null
	(Invoke-WebRequest 'https://maven.apache.org/download.html').Content -split '<a ' | ForEach-Object {
		if ($_ -match '(?s)(?<=\bhref=")([^"]+/apache-maven-([0-9]+(?:\.[0-9]+){0,3})-bin.zip)(?=")') {
			$Version = [TlcSemanticVersion]::new($Matches[2])
			if ($Version -notin $TlcPackageConfig.Tags -and (-not $PkgInfo -or $Version.LaterThan($PkgInfo.Version))) {
				$PkgInfo = @{Version = $Version; URI = $Matches[1]}
			}
		}
	}
	if (-not $Version) {
		Write-Error 'No maven release found on website'
	}
	if (-not $PkgInfo) {
		$TlcPackageConfig.Version = $Version.ToString()
		$TlcPackageConfig.UpToDate = $true
		return
	}
	$TlcPackageConfig.Version = $PkgInfo.Version.ToString()
	Write-Output "Installing maven v$($TlcPackageConfig.Version)..."
	Install-BuildTool 'maven.zip' $PkgInfo.URI "$env:Temp\maven-unzip"
	Move-Item (Get-Item "$env:Temp\maven-unzip\*") '\pkg'
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'mvn.cmd' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		mvn -version
	}
}
