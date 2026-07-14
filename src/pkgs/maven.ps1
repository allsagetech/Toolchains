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
	$metadata = Invoke-TlcRestMethod -Uri 'https://repo1.maven.org/maven2/org/apache/maven/apache-maven/maven-metadata.xml'
	$Version = Get-TlcMavenReleaseVersion -Metadata $metadata
	$TlcPackageConfig.Version = $Version.ToString()
	$TlcPackageConfig.UpToDate = -not $Version.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }
	$uri = "https://dlcdn.apache.org/maven/maven-3/$Version/binaries/apache-maven-$Version-bin.zip"
	Write-Output "Installing maven v$($TlcPackageConfig.Version)..."
	$expectedSha512 = Get-TlcRemoteHash -ChecksumUri "$uri.sha512" -Algorithm SHA512
	Install-BuildTool -AssetName 'maven.zip' -AssetURL $uri -ToolDir "$env:Temp\maven-unzip" -ExpectedHash $expectedSha512 -ExpectedHashAlgorithm SHA512
	Move-Item (Get-Item "$env:Temp\maven-unzip\*") (Get-TlcPkgRoot)
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'mvn.cmd' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		mvn -version
	}
}
