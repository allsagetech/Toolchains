<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'gradle'
	Matcher = '^gradle-7\.'
	BuildRevision = 1
	SecurityOverlays = @(
		@{ Name = 'jackson-core'; Version = '2.18.8'; GroupPath = 'com/fasterxml/jackson/core'; ExpectedSha256 = 'ab865e39f01403598748b090a3bf528616e701913a71afc37a227daa0fabb4ae' },
		@{ Name = 'jackson-databind'; Version = '2.18.8'; GroupPath = 'com/fasterxml/jackson/core'; ExpectedSha256 = '06ea5950905263fac3e1730de6a21a023151626af6bb3cb099f88644a0fa04f0' },
		@{ Name = 'jackson-annotations'; Version = '2.18.4'; GroupPath = 'com/fasterxml/jackson/core'; ExpectedSha256 = '2166156094cd146397eb4814bd117cabe3353390dfa894bcc06ce46b15bd428e' },
		@{ Name = 'bcpg-jdk18on'; Version = '1.84'; GroupPath = 'org/bouncycastle'; ExpectedSha256 = 'c0e6303a0d7589040f400950ecee87a14b81312e84ed15e5390ebb0c4566ddab' },
		@{ Name = 'bcprov-jdk18on'; Version = '1.84'; GroupPath = 'org/bouncycastle'; ExpectedSha256 = '64d6c5a6121fcd927152dd182cbed39afe0fda641a970d9bcc0c9cb1858b2731' },
		@{ Name = 'bcutil-jdk18on'; Version = '1.84'; GroupPath = 'org/bouncycastle'; ExpectedSha256 = 'b374e16963421fb9cfb01cc20d7ad8fd2f8b8188e3eef0ec0a8965e245f7619a' },
		@{ Name = 'plexus-utils'; Version = '3.6.1'; GroupPath = 'org/codehaus/plexus'; ExpectedSha256 = '05a63effd67e2d6b9d610cc82e2bd7473289d34802e57a529b28110f28af5679' }
	)
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'gradle'
		Repo = 'gradle'
		TagPattern = '^v(7)\.([0-9]+)\.([0-9]+)$'
	}
	$Latest = Get-GitHubTag @Params
	$upstreamVersion = $Latest.Version.ToString()
	$packageVersion = [TlcSemanticVersion]::new("$upstreamVersion+$($TlcPackageConfig.BuildRevision)")
	$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $packageVersion.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$Version = $Tag.SubString(1)
	if ($Version.EndsWith('.0')) {
		$Version = $Version.SubString(0, $Version.Length - 2)
	}
	$AssetName = "gradle-$Version-bin.zip"
	$Params = @{
		AssetName = $AssetName
		AssetURL = "https://services.gradle.org/distributions/$AssetName"
		ExpectedSha256 = Get-TlcRemoteSha256 -ChecksumUri "https://services.gradle.org/distributions/$AssetName.sha256"
	}
	Install-BuildTool @Params
	$overlayPlans = foreach ($overlay in @($TlcPackageConfig.SecurityOverlays)) {
		$existing = @(Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -File -Filter "$($overlay.Name)-*.jar")
		if ($existing.Count -ne 1) { throw "Expected exactly one $($overlay.Name) Gradle library, found $($existing.Count)." }
		if ($existing[0].BaseName -notmatch "^$([regex]::Escape([string]$overlay.Name))-(?<Version>[0-9]+(?:\.[0-9]+){1,3})$") { throw "Could not parse the bundled $($overlay.Name) version." }
		if ([version]$Matches.Version -ge [version]$overlay.Version) { continue }
		$fileName = "$($overlay.Name)-$($overlay.Version).jar"
		$uri = "https://repo.maven.apache.org/maven2/$($overlay.GroupPath)/$($overlay.Name)/$($overlay.Version)/$fileName"
		$stagedPath = Get-TlcStagingPath "gradle-security-overlays\$fileName"
		Invoke-TlcWebRequest -Uri $uri -OutFile $stagedPath -ExpectedSha256 $overlay.ExpectedSha256 | Out-Null
		[pscustomobject]@{ Existing = $existing[0].FullName; Staged = $stagedPath; Name = $overlay.Name; ExpectedSha256 = $overlay.ExpectedSha256 }
	}
	foreach ($plan in $overlayPlans) {
		Copy-Item -LiteralPath $plan.Staged -Destination $plan.Existing -Force
		if ((Get-FileHash -LiteralPath $plan.Existing -Algorithm SHA256).Hash -cne ([string]$plan.ExpectedSha256).ToUpperInvariant()) { throw "Gradle security overlay failed for $($plan.Name)." }
	}
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
