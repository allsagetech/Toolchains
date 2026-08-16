<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'gradle'
	Matcher = '^gradle-9\.'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'gradle'
		Repo = 'gradle'
		TagPattern = '^v(9)\.([0-9]+)\.([0-9]+)$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$Version = $Tag.SubString(1)
	$AssetName = "gradle-$Version-bin.zip"
	$Params = @{
		AssetName = $AssetName
		AssetURL = "https://services.gradle.org/distributions/$AssetName"
		ExpectedSha256 = Get-TlcRemoteSha256 -ChecksumUri "https://services.gradle.org/distributions/$AssetName.sha256"
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'gradle.bat' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		$contractRoot = Join-Path $env:TEMP "toolchains-gradle-contract-$([Guid]::NewGuid().ToString('n'))"
		$originalGradleUserHome = $env:GRADLE_USER_HOME
		$originalJavaHome = $env:JAVA_HOME
		try {
			if ($env:JAVA_HOME_17_X64) { $env:JAVA_HOME = $env:JAVA_HOME_17_X64 }
			$env:GRADLE_USER_HOME = Join-Path $contractRoot 'home'
			New-Item -ItemType Directory -Path $contractRoot -Force | Out-Null
			'tasks.register("verifyToolchain") { doLast { println("toolchains-gradle-contract") } }' | Set-Content -LiteralPath (Join-Path $contractRoot 'build.gradle')
			gradle --version
			if ($LASTEXITCODE -ne 0) { throw "Gradle version contract failed with exit code $LASTEXITCODE." }
			gradle --no-daemon -p $contractRoot verifyToolchain
			if ($LASTEXITCODE -ne 0) { throw "Gradle task contract failed with exit code $LASTEXITCODE." }
		} finally {
			$env:GRADLE_USER_HOME = $originalGradleUserHome
			$env:JAVA_HOME = $originalJavaHome
			Remove-Item -LiteralPath $contractRoot -Recurse -Force -ErrorAction SilentlyContinue
		}
	}
}
