<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

BeforeAll {
	$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
	. (Join-Path $script:RepoRoot 'src/main.ps1')
	function global:Invoke-TlcFixtureTar {
		$mode = [string]$args[0]
		$global:LASTEXITCODE = 0
		switch ($mode) {
			'-tzf' { return @($global:TlcFixtureTarEntries) }
			'-tvzf' { return @($global:TlcFixtureTarDetails) }
			'-xzf' {
				$destinationIndex = [Array]::IndexOf($args, '-C')
				$extractRoot = [string]$args[$destinationIndex + 1]
				$packageRoot = Join-Path $extractRoot 'package'
				New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
				[ordered]@{ name = $global:TlcFixtureTarName; version = $global:TlcFixtureTarVersion } |
					ConvertTo-Json | Set-Content -LiteralPath (Join-Path $packageRoot 'package.json') -Encoding utf8
			}
			default { $global:LASTEXITCODE = 2 }
		}
	}
}

AfterAll {
	Remove-Item Function:\Invoke-TlcFixtureTar -Force -ErrorAction SilentlyContinue
	Remove-Variable TlcFixtureTarEntries,TlcFixtureTarDetails,TlcFixtureTarName,TlcFixtureTarVersion -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Package family lifecycle helpers' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-family-$([Guid]::NewGuid().ToString('n'))"
		New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
		$script:OldPkgRoot = $env:TLC_PKG_ROOT
		$script:OldStagingRoot = $env:TLC_STAGING_ROOT
		$env:TLC_PKG_ROOT = Join-Path $script:TempRoot 'pkg'
		$env:TLC_STAGING_ROOT = Join-Path $script:TempRoot 'stage'
	}

	AfterEach {
		Clear-TlcPackageScript
		$env:TLC_PKG_ROOT = $script:OldPkgRoot
		$env:TLC_STAGING_ROOT = $script:OldStagingRoot
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'tracks Node family versions and stages a new release' {
		Initialize-TlcNodePackage -Major 22 -LifecycleNote 'active'
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new('21.0.0')
		Mock Get-GitHubTag { @{ name = 'v22.3.1'; Version = [TlcSemanticVersion]::new('22.3.1') } }
		Mock Install-BuildTool {}
		Mock Get-ChildItem { [pscustomobject]@{ DirectoryName = (Join-Path $env:TLC_PKG_ROOT 'node') } }
		Mock Write-TlcVars {}
		Install-TlcPackage
		$global:TlcPackageConfig.Version | Should -Be '22.3.1'
		$global:TlcPackageConfig.UpToDate | Should -BeFalse
		Should -Invoke Install-BuildTool -Times 1
		Should -Invoke Write-TlcVars -Times 1
	}

	It 'revisions Node packages and installs each pinned npm security overlay' {
		$hash = 'a' * 128
		Initialize-TlcNodePackage -Major 22 -BuildRevision 1 -NpmVersion '12.0.2' -NpmExpectedSha512 $hash `
			-NpmDependencyOverlays @{
				'brace-expansion' = @{ Version = '5.0.9'; ExpectedSha512 = $hash }
				'ip-address' = @{ Version = '10.5.0'; ExpectedSha512 = $hash }
			}
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new('22.3.1')
		Mock Get-GitHubTag { @{ name = 'v22.3.1'; Version = [TlcSemanticVersion]::new('22.3.1') } }
		Mock Install-BuildTool {}
		Mock Get-ChildItem { [pscustomobject]@{ DirectoryName = (Join-Path $env:TLC_PKG_ROOT 'node') } }
		Mock Install-TlcPinnedNpmArchive {}
		Mock Write-TlcVars {}
		Install-TlcPackage
		$global:TlcPackageConfig.Version | Should -Be '22.3.1+1'
		$global:TlcPackageConfig.UpToDate | Should -BeFalse
		Should -Invoke Install-TlcPinnedNpmArchive -Times 3 -Exactly
		Should -Invoke Install-TlcPinnedNpmArchive -Times 1 -Exactly -ParameterFilter { $Name -eq 'npm' -and $Version -eq '12.0.2' }
		Should -Invoke Install-TlcPinnedNpmArchive -Times 1 -Exactly -ParameterFilter { $Name -eq 'brace-expansion' -and $Version -eq '5.0.9' }
		Should -Invoke Install-TlcPinnedNpmArchive -Times 1 -Exactly -ParameterFilter { $Name -eq 'ip-address' -and $Version -eq '10.5.0' }
	}

	It 'installs a registry-integrity-verified npm archive inside the package root' {
		$global:TlcFixtureTarEntries = @('package/package.json', 'package/bin/npm-cli.js')
		$global:TlcFixtureTarDetails = @('-rw-r--r-- package/package.json', '-rw-r--r-- package/bin/npm-cli.js')
		$global:TlcFixtureTarName = 'npm'
		$global:TlcFixtureTarVersion = '12.0.2'
		Mock Get-TlcApplicationPath { 'Invoke-TlcFixtureTar' } -ParameterFilter { $Name -eq 'tar' }
		Mock Invoke-TlcWebRequest {
			New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null
			Set-Content -LiteralPath $OutFile -Value 'fixture' -NoNewline
		}
		$destination = Join-Path $env:TLC_PKG_ROOT 'node\node_modules\npm'
		Install-TlcPinnedNpmArchive -Name npm -Version '12.0.2' -ExpectedSha512 ('a' * 128) -Destination $destination
		$manifest = Get-Content -LiteralPath (Join-Path $destination 'package.json') -Raw | ConvertFrom-Json
		$manifest.name | Should -BeExactly 'npm'
		$manifest.version | Should -BeExactly '12.0.2'
		Should -Invoke Invoke-TlcWebRequest -Times 1 -Exactly -ParameterFilter {
			$Uri -eq 'https://registry.npmjs.org/npm/-/npm-12.0.2.tgz' -and
			$ExpectedHashAlgorithm -eq 'SHA512' -and $ExpectedHash -eq ('a' * 128)
		}
	}

	It 'rejects npm archive traversal and link entries before extraction' {
		$global:TlcFixtureTarName = 'npm'
		$global:TlcFixtureTarVersion = '12.0.2'
		Mock Get-TlcApplicationPath { 'Invoke-TlcFixtureTar' } -ParameterFilter { $Name -eq 'tar' }
		Mock Invoke-TlcWebRequest {
			New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null
			Set-Content -LiteralPath $OutFile -Value 'fixture' -NoNewline
		}
		$destination = Join-Path $env:TLC_PKG_ROOT 'node\node_modules\npm'
		$global:TlcFixtureTarEntries = @('package/../escape')
		$global:TlcFixtureTarDetails = @('-rw-r--r-- package/../escape')
		{ Install-TlcPinnedNpmArchive -Name npm -Version '12.0.2' -ExpectedSha512 ('a' * 128) -Destination $destination } |
			Should -Throw '*unsafe path*'
		$global:TlcFixtureTarEntries = @('package/package.json')
		$global:TlcFixtureTarDetails = @('lrwxr-xr-x package/link -> ../../escape')
		{ Install-TlcPinnedNpmArchive -Name npm -Version '12.0.2' -ExpectedSha512 ('a' * 128) -Destination $destination } |
			Should -Throw '*contains links*'
	}

	It 'rejects npm archive identity mismatches and destinations outside the package root' {
		$global:TlcFixtureTarEntries = @('package/package.json')
		$global:TlcFixtureTarDetails = @('-rw-r--r-- package/package.json')
		$global:TlcFixtureTarName = 'not-npm'
		$global:TlcFixtureTarVersion = '12.0.2'
		Mock Get-TlcApplicationPath { 'Invoke-TlcFixtureTar' } -ParameterFilter { $Name -eq 'tar' }
		Mock Invoke-TlcWebRequest {
			New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null
			Set-Content -LiteralPath $OutFile -Value 'fixture' -NoNewline
		}
		$destination = Join-Path $env:TLC_PKG_ROOT 'node\node_modules\npm'
		{ Install-TlcPinnedNpmArchive -Name npm -Version '12.0.2' -ExpectedSha512 ('a' * 128) -Destination $destination } |
			Should -Throw '*identity mismatch*'
		$outside = Join-Path $script:TempRoot 'outside\npm'
		{ Install-TlcPinnedNpmArchive -Name npm -Version '12.0.2' -ExpectedSha512 ('a' * 128) -Destination $outside } |
			Should -Throw '*outside package root*'
		{ Install-TlcPinnedNpmArchive -Name '..\npm' -Version '12.0.2' -ExpectedSha512 ('a' * 128) -Destination $destination } |
			Should -Throw
		{ Install-TlcPinnedNpmArchive -Name npm -Version '..\12.0.2' -ExpectedSha512 ('a' * 128) -Destination $destination } |
			Should -Throw
	}

	It 'short-circuits current Adoptium, K9s, and kubectl families' {
		Initialize-TlcAdoptiumPackage -Kind jdk -Major 21 -IncludeX86
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new('21.0.8')
		Mock Get-GitHubRelease { @{ Name = 'jdk.zip'; URL = 'https://example.test/jdk.zip'; Version = [TlcSemanticVersion]::new('21.0.8') } }
		Install-TlcPackage
		$global:TlcPackageConfig.UpToDate | Should -BeTrue

		Initialize-TlcK9sPackage -Name 'k9s-linux' -Linux
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new('0.51.0+1')
		Install-TlcPackage
		$global:TlcPackageConfig.Platform | Should -Be 'linux/amd64'
		$global:TlcPackageConfig.UpToDate | Should -BeTrue

		Initialize-TlcKubectlPackage -Name 'kubectl-linux' -Linux
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new('1.34.2+1')
		Mock Invoke-TlcWebRequest { [pscustomobject]@{ Content = 'v1.34.2' } }
		Install-TlcPackage
		$global:TlcPackageConfig.Version | Should -Be '1.34.2+1'
		$global:TlcPackageConfig.UpToDate | Should -BeTrue
	}

	It 'installs a checksum-verified direct GitHub CLI asset' {
		Initialize-TlcGitHubCliPackage -Name 'fixture' -CanonicalName 'fixture' -Owner owner -Repo repo -AssetPattern '^fixture$' -BinaryName 'fixture.exe' -ArchiveType direct
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new('1.0.0')
		Mock Get-GitHubRelease { @{ Name = 'fixture.bin'; URL = 'https://example.test/fixture.bin'; Version = [TlcSemanticVersion]::new('1.2.0') } }
		Mock Get-TlcGitHubReleaseAssetSha256 { 'a' * 64 }
		Mock Invoke-TlcWebRequest {
			New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null
			[IO.File]::WriteAllText($OutFile, 'fixture')
			[pscustomobject]@{ StatusCode = 200 }
		}
		Install-TlcPackage
		$global:TlcPackageConfig.Version | Should -Be '1.2.0'
		Test-Path -LiteralPath (Join-Path $env:TLC_PKG_ROOT 'fixture.exe') | Should -BeTrue
		Test-Path -LiteralPath (Join-Path $env:TLC_PKG_ROOT '.tlc') | Should -BeTrue
	}
}

Describe 'Utility integrity and metadata helpers' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-util-$([Guid]::NewGuid().ToString('n'))"
		New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
		$script:OldPkgRoot = $env:TLC_PKG_ROOT
		$script:OldHfToken = $env:HF_TOKEN
		$env:TLC_PKG_ROOT = $script:TempRoot
	}

	AfterEach {
		$env:TLC_PKG_ROOT = $script:OldPkgRoot
		$env:HF_TOKEN = $script:OldHfToken
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'writes portable definitions and resolves applications' {
		Get-TlcApplicationPath -Name 'pwsh' | Should -Match 'pwsh(?:\.exe)?$'
		Write-TlcVars @{ env = @{ path = "$script:TempRoot/bin" } }
		$content = Get-Content -LiteralPath (Join-Path $script:TempRoot '.tlc') -Raw
		$content | Should -Match '\$\{\.\}'
		{ Get-TlcApplicationPath -Name 'definitely-not-a-real-toolchain-command' } | Should -Throw
	}

	It 'isolates native stderr and fails only on a nonzero process exit' {
		ConvertTo-TlcNativeCommandLineArgument -Argument plain | Should -BeExactly 'plain'
		ConvertTo-TlcNativeCommandLineArgument -Argument '' | Should -BeExactly '""'
		ConvertTo-TlcNativeCommandLineArgument -Argument 'two words' | Should -BeExactly '"two words"'
		ConvertTo-TlcNativeCommandLineArgument -Argument 'quoted"value' | Should -BeExactly '"quoted\"value"'
		ConvertTo-TlcNativeCommandLineArgument -Argument 'C:\Program Files\tool\' | Should -BeExactly '"C:\Program Files\tool\\"'

		$hostExecutable = (Get-Process -Id $PID).Path
		$errorsBefore = $Error.Count
		$output = Invoke-TlcNativeCommand -FilePath $hostExecutable -ArgumentList @(
			'-NoProfile', '-NonInteractive', '-Command',
			'[Console]::Error.WriteLine(123);[Console]::Out.WriteLine(456);exit 0'
		) -FailureMessage 'native success probe failed' -PassThru 6>$null
		$output.Trim() | Should -BeExactly '456'
		($Error.Count - $errorsBefore) | Should -Be 0
		$nativeWorkingDirectory = Invoke-TlcNativeCommand -FilePath $hostExecutable -ArgumentList @(
			'-NoProfile', '-NonInteractive', '-Command',
			'[Console]::Out.Write([Environment]::CurrentDirectory);exit 0'
		) -FailureMessage 'native working-directory probe failed' -PassThru 6>$null
		[IO.Path]::GetFullPath($nativeWorkingDirectory.Trim()) | Should -BeExactly ([IO.Path]::GetFullPath((Get-Location).ProviderPath))

		{
			Invoke-TlcNativeCommand -FilePath $hostExecutable -ArgumentList @(
				'-NoProfile', '-NonInteractive', '-Command',
				'[Console]::Out.WriteLine(678);[Console]::Error.WriteLine(789);exit 7'
			) -FailureMessage 'native failure probe failed' 6>$null
		} | Should -Throw '*native failure probe failed*exit code 7*678*789*'
	}

	It 'builds Hugging Face headers, slugs, versions, and allowlists' {
		$env:HF_TOKEN = 'secret'
		(Get-TlcHfHeaders).Authorization | Should -Be 'Bearer secret'
		Get-TlcHfModelCacheSlug -Repo 'Owner/Model' | Should -Be 'models--Owner--Model'
		{ Get-TlcHfModelCacheSlug -Repo 'invalid' } | Should -Throw '*owner/name*'
		(Get-TlcHfModelAllowPatterns -ExtraPatterns @('*.gguf')) | Should -Contain '*.gguf'
		Mock Invoke-TlcRestMethod { @{ lastModified = '2026-08-15T12:34:00Z' } }
		Get-TlcHfModelVersion -Repo 'Owner/Model' | Should -Be '2026.8.15+1234'
	}

	It 'validates SHA-256 and SHA-512 files and parses remote checksums' {
		$file = Join-Path $script:TempRoot 'asset.bin'
		[IO.File]::WriteAllText($file, 'verified')
		$sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
		$sha512 = (Get-FileHash -LiteralPath $file -Algorithm SHA512).Hash.ToLowerInvariant()
		Assert-TlcDownloadedFile -Path $file -Uri 'https://example.test/a' -ExpectedSha256 $sha256
		Assert-TlcDownloadedFile -Path $file -Uri 'https://example.test/a' -ExpectedHash $sha512 -ExpectedHashAlgorithm SHA512
		{ Assert-TlcDownloadedFile -Path $file -Uri 'https://example.test/a' -ExpectedSha256 ('0' * 64) } | Should -Throw '*mismatch*'
		Mock Invoke-TlcWebRequest { [pscustomobject]@{ Content = "$sha256  asset.bin`n" } }
		Get-TlcRemoteSha256 -ChecksumUri 'https://example.test/checksums' -AssetName 'asset.bin' | Should -Be $sha256
		Get-TlcRemoteHash -ChecksumUri 'https://example.test/checksums' -AssetName 'asset.bin' -Algorithm SHA256 | Should -Be $sha256
	}

	It 'selects stable release assets and official .NET metadata' {
		$selection = Select-TlcGitHubReleaseAsset -Releases @(
			[pscustomobject]@{ tag_name = 'v2.0.0-beta'; prerelease = $true; assets = @([pscustomobject]@{ name = 'tool.zip'; browser_download_url = 'https://example.test/pre.zip' }) },
			[pscustomobject]@{ tag_name = 'v1.4.0'; prerelease = $false; assets = @([pscustomobject]@{ name = 'tool.zip'; browser_download_url = 'https://example.test/tool.zip'; digest = ('sha256:' + ('a' * 64)) }) }
		) -AssetPattern '^tool\.zip$' -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
		$selection.Version.ToString() | Should -Be '1.4.0'
		$result = ConvertTo-TlcGitHubReleaseAssetResult -Selection $selection
		$result.Name | Should -Be 'tool.zip'
		$result.ExpectedSha256 | Should -Be ('a' * 64)
		$script:TlcKnownAssetSha256['https://example.test/tool.zip'] | Should -Be ('a' * 64)
		Get-Variable -Name TlcKnownAssetSha256 -Scope Global -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
		Find-LatestTag -List @([pscustomobject]@{ tag = 'v1.2.0' }, [pscustomobject]@{ tag = 'v1.10.0' }) -TagProperty tag -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$' | ForEach-Object { $_.Version.ToString() | Should -Be '1.10.0' }
		Find-LatestTag -List @([pscustomobject]@{ tag = 'v26.7.0' }, [pscustomobject]@{ tag = 'v22.18.0' }) -TagProperty tag -TagPattern '^v(22)\.([0-9]+)\.([0-9]+)$' | ForEach-Object { $_.Version.ToString() | Should -Be '22.18.0' }
		Find-LatestTag -List @([pscustomobject]@{ tag = 'not-a-version' }) -TagProperty tag -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$' | Should -BeNullOrEmpty

		$metadata = @{ 'releases-index' = @(@{ 'channel-version' = '8.0'; 'support-phase' = 'active'; 'releases.json' = 'https://example.test/releases.json' }) }
		$releases = @{ releases = @(@{ 'release-date' = '2026-01-01'; sdk = @{ version = '8.0.101'; files = @(@{ rid = 'win-x64'; url = 'https://example.test/sdk.zip'; hash = ('b' * 128); name = 'sdk.zip' }) } }) }
		Mock Invoke-TlcRestMethod { if ($Uri -match 'releases-index') { $metadata } else { $releases } }
		$asset = Get-DotNetReleaseAsset -Rid 'win-x64' -Product sdk -Extension '.zip'
		$asset.VersionText | Should -Be '8.0.101'
		$asset.HashAlgorithm | Should -Be 'SHA512'
	}
}

Describe 'Network and main policy branches' {
	AfterEach { Clear-TlcPackageScript }

	It 'builds authenticated request headers and retries transient REST failures' {
		$oldToken = $env:GH_TOKEN
		try {
			$env:GH_TOKEN = 'token'
			(Get-TlcGitHubHeaders).Authorization | Should -Be 'Bearer token'
			(Get-TlcRequestHeaders -Headers @{ Accept = 'application/json' }).Accept | Should -Be 'application/json'
			$script:attempt = 0
			Mock Start-Sleep {}
			Mock Invoke-RestMethod { $script:attempt++; if ($script:attempt -lt 2) { throw 'temporary' }; @{ ok = $true } }
			(Invoke-TlcRestMethod -Uri 'https://example.test/api' -MaxRetries 2).ok | Should -BeTrue
			$script:attempt | Should -Be 2
		} finally { $env:GH_TOKEN = $oldToken }
	}

	It 'applies runner, publication, signing, and build fail-closed defaults' {
		Get-TlcPackageRunsOn -Config @{ RunsOn = 'ubuntu-22.04' } | Should -Be 'ubuntu-22.04'
		Get-TlcPackagePublishRunsOn -Config @{ RunsOn = 'ubuntu-22.04' } | Should -Be 'ubuntu-22.04'
		Get-TlcPackagePublishRunsOn -Config @{ PublishRunsOn = 'windows-2025' } | Should -Be 'windows-2025'
		$oldSign = $env:TLC_COSIGN_SIGN
		try { $env:TLC_COSIGN_SIGN = 'true'; Test-CosignSigningEnabled | Should -BeTrue } finally { $env:TLC_COSIGN_SIGN = $oldSign }
		$oldRoot = $env:TLC_PKG_ROOT
		try {
			$env:TLC_PKG_ROOT = Join-Path ([IO.Path]::GetTempPath()) "missing-$([Guid]::NewGuid().ToString('n'))"
			{ Invoke-DockerBuild -Tag t -PkgName p -PkgVersion 1 -Config @{} } | Should -Throw '*does not exist*'
		} finally { $env:TLC_PKG_ROOT = $oldRoot }
	}

	It 'ignores colliding registry tags that are not package versions' {
		$global:TlcPackageConfig = @{ Name = 'docker' }
		Mock Get-DockerTags { @{ tags = @('docker-desktop-4.86.0', 'docker-29.7.2') } }
		Invoke-TlcInit
		$global:TlcPackageConfig.Latest.ToString() | Should -Be '29.7.2'
		@($global:TlcPackageConfig.Tags).Count | Should -Be 1
	}

	It 'validates descriptor schema branches before publication' {
		$global:TlcPackageConfig = @{ Name = 'valid'; Platform = 'windows/amd64'; Tier = 'tooling' }
		function global:Install-TlcPackage {}
		function global:Test-TlcPackageInstall {}
		{ Test-TlcPackageScript } | Should -Not -Throw

		$global:TlcPackageConfig.Platform = 'plan9/amd64'
		{ Test-TlcPackageScript } | Should -Throw '*unsupported package platform*'
		$global:TlcPackageConfig.Platform = 'windows/amd64'
		$global:TlcPackageConfig.Tier = 'unknown'
		{ Test-TlcPackageScript } | Should -Throw '*unsupported*TlcPackageConfig tier*'
		$global:TlcPackageConfig.Tier = 'tooling'
		$global:TlcPackageConfig.VerifiedDownloads = $false
		{ Test-TlcPackageScript } | Should -Throw '*UnverifiedDownloadReason*'
		$global:TlcPackageConfig.VerifiedDownloads = $true
		$global:TlcPackageConfig.PublishEligible = $false
		{ Test-TlcPackageScript } | Should -Throw '*PublicationBlockReason*'
	}
}
