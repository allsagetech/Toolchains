<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

BeforeAll {
	$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
	. (Join-Path $script:RepoRoot 'src/main.ps1')
}

Describe 'Expanded package family lifecycles' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-families-$([Guid]::NewGuid().ToString('n'))"
		$script:OldPkgRoot = $env:TLC_PKG_ROOT
		$script:OldStagingRoot = $env:TLC_STAGING_ROOT
		$env:TLC_PKG_ROOT = Join-Path $script:TempRoot 'pkg'
		$env:TLC_STAGING_ROOT = Join-Path $script:TempRoot 'stage'
		New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
	}

	AfterEach {
		Clear-TlcPackageScript
		$env:TLC_PKG_ROOT = $script:OldPkgRoot
		$env:TLC_STAGING_ROOT = $script:OldStagingRoot
		Remove-Item Function:\chmod -Force -ErrorAction SilentlyContinue
		Remove-Item Function:\go-fixture -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'installs both Adoptium architectures and exercises JDK validation' {
		Initialize-TlcAdoptiumPackage -Kind jdk -Major 21 -IncludeX86
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new('20.0.0')
		Mock Get-GitHubRelease { @{ Name = 'OpenJDK21U-jdk_x64_windows_hotspot_21.0.8.zip'; URL = 'https://example.test/x64.zip'; Version = [TlcSemanticVersion]::new('21.0.8') } }
		Mock Install-BuildTool {
			$root = Join-Path $ToolDir 'jdk-21/bin'
			New-Item -ItemType Directory -Path $root -Force | Out-Null
			[IO.File]::WriteAllText((Join-Path $root 'java.exe'), 'java')
			[IO.File]::WriteAllText((Join-Path $root 'javac.exe'), 'javac')
		}
		Mock Toolchain {}
		Install-TlcPackage
		$global:TlcPackageConfig.UpToDate | Should -BeFalse
		Test-Path -LiteralPath (Get-TlcPkgPath 'x64') | Should -BeTrue
		Test-Path -LiteralPath (Get-TlcPkgPath 'x86') | Should -BeTrue
		Test-TlcPackageInstall
		Should -Invoke Install-BuildTool -Times 2
		Should -Invoke Toolchain -Times 2
	}

	It 'allows an unavailable optional Adoptium x86 asset and validates a JRE' {
		Initialize-TlcAdoptiumPackage -Kind jre -Major 8 -IncludeX86
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new()
		Mock Get-GitHubRelease { @{ Name = 'OpenJDK8U-jre_x64_windows_hotspot_8u462b08.zip'; URL = 'https://example.test/x64.zip'; Version = [TlcSemanticVersion]::new('8.462.8') } }
		Mock Install-BuildTool {
			if ($AssetName -like '*x86-32*') { throw 'Not Found' }
			$root = Join-Path $ToolDir 'jre-8/bin'
			New-Item -ItemType Directory -Path $root -Force | Out-Null
			[IO.File]::WriteAllText((Join-Path $root 'java.exe'), 'java')
		}
		Mock Toolchain {}
		Install-TlcPackage
		Test-Path -LiteralPath (Get-TlcPkgPath 'x86') | Should -BeFalse
		Test-TlcPackageInstall
		Should -Invoke Toolchain -Times 1
	}

	It 'builds patched K9s packages for Windows and Linux' {
		Mock Invoke-TlcVerifiedGoCommandBuild {
			New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
			[IO.File]::WriteAllText($OutputPath, 'k9s')
		}
		Mock Toolchain {}
		Initialize-TlcK9sPackage -Name k9s
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new()
		Install-TlcPackage
		Test-TlcPackageInstall
		Test-Path -LiteralPath (Get-TlcPkgPath 'k9s.exe') | Should -BeTrue

		Clear-TlcPackageScript
		Remove-Item -LiteralPath $env:TLC_PKG_ROOT -Recurse -Force
		function global:chmod { $global:LASTEXITCODE = 0 }
		Initialize-TlcK9sPackage -Name k9s-linux -Linux
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new()
		Install-TlcPackage
		Test-Path -LiteralPath (Get-TlcPkgPath 'k9s') | Should -BeTrue
		Should -Invoke Invoke-TlcVerifiedGoCommandBuild -Times 2
	}

	It 'builds kubectl from checksum-verified Go modules' {
		$infoPath = Join-Path $script:TempRoot 'module.info'
		[IO.File]::WriteAllText($infoPath, '{"Time":"2026-08-15T12:00:00Z"}')
		$script:GoInfoPath = $infoPath
		Mock Invoke-TlcNativeCommand {
			$call = $ArgumentList -join ' '
			if ($call -eq 'list -m all') {
				return (@(
					'toolchains.local/test v0.0.0',
					'k8s.io/component-base v0.34.2',
					'k8s.io/kubectl v0.34.2',
					'k8s.io/client-go v0.34.2',
					'golang.org/x/net v0.56.0',
					'golang.org/x/sys v0.46.0',
					'golang.org/x/text v0.39.0'
				) -join [Environment]::NewLine)
			}
			if ($call -like 'mod download -json*') {
				return (@{ Origin = @{ Hash = 'a' * 40 }; Info = $script:GoInfoPath } | ConvertTo-Json -Compress)
			}
			if ($ArgumentList[0] -eq 'build') {
				$index = [Array]::IndexOf([object[]]$ArgumentList, '-o')
				[IO.File]::WriteAllText([string]$ArgumentList[$index + 1], 'kubectl')
			}
		}
		Mock Get-TlcApplicationPath { 'go-fixture' }
		Mock Invoke-TlcWebRequest { [pscustomobject]@{ Content = [Text.Encoding]::UTF8.GetBytes('v1.34.2') } }
		Mock Toolchain {}
		Initialize-TlcKubectlPackage -Name kubectl
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new()
		Install-TlcPackage
		$global:TlcPackageConfig.Version | Should -Be '1.34.2+1'
		Test-Path -LiteralPath (Get-TlcPkgPath 'kubectl.exe') | Should -BeTrue
		Test-TlcPackageInstall
		Should -Invoke Toolchain -Times 1
		Should -Invoke Invoke-TlcNativeCommand -Times 6 -Exactly
	}

	It 'rejects malformed kubectl upstream version text' {
		Initialize-TlcKubectlPackage -Name kubectl
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new()
		Mock Invoke-TlcWebRequest { [pscustomobject]@{ Content = 'latest' } }
		{ Install-TlcPackage } | Should -Throw '*unexpected kubectl stable version*'
	}

	It 'installs zip and tar.gz GitHub CLI families and invokes their version checks' {
		$script:ArchiveKind = 'zip'
		Mock Get-GitHubRelease { @{ Name = "fixture.$script:ArchiveKind"; URL = 'https://example.test/fixture'; Version = [TlcSemanticVersion]::new('2.0.0') } }
		Mock Get-TlcGitHubReleaseAssetSha256 { 'a' * 64 }
		Mock Invoke-TlcWebRequest {
			if ($script:ArchiveKind -eq 'zip') {
				$sourceRoot = Join-Path $script:TempRoot 'archive-source'
				New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
				[IO.File]::WriteAllText((Join-Path $sourceRoot 'fixture.exe'), 'fixture')
				Compress-Archive -Path (Join-Path $sourceRoot '*') -DestinationPath $OutFile -Force
			} else {
				[IO.File]::WriteAllText($OutFile, 'archive')
			}
			[pscustomobject]@{ StatusCode = 200 }
		}
		Mock Toolchain {}

		Initialize-TlcGitHubCliPackage -Name fixture -CanonicalName fixture -Owner o -Repo r -AssetPattern x -BinaryName fixture.exe -ArchiveType zip
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new()
		Install-TlcPackage
		Test-TlcPackageInstall
		Test-Path -LiteralPath (Get-TlcPkgPath 'fixture.exe') | Should -BeTrue

		Clear-TlcPackageScript
		Remove-Item -LiteralPath $env:TLC_PKG_ROOT -Recurse -Force
		$script:ArchiveKind = 'tar.gz'
		function global:chmod { $global:LASTEXITCODE = 0 }
		function global:tar {
			$global:LASTEXITCODE = 0
			$destination = [string]$args[[Array]::IndexOf([object[]]$args, '-C') + 1]
			[IO.File]::WriteAllText((Join-Path $destination 'fixture'), 'fixture')
		}
		Mock Get-TlcApplicationPath { 'tar' }
		Initialize-TlcGitHubCliPackage -Name fixture-linux -CanonicalName fixture -Owner o -Repo r -AssetPattern x -BinaryName fixture -ArchiveType tar.gz -Linux
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new()
		Install-TlcPackage
		Test-Path -LiteralPath (Get-TlcPkgPath 'fixture') | Should -BeTrue
		Should -Invoke Get-TlcGitHubReleaseAssetSha256 -Times 2
	}

	It 'uses companion GitHub checksums and fails closed when none exist' {
		Initialize-TlcGitHubCliPackage -Name fixture -CanonicalName fixture -Owner o -Repo r -AssetPattern asset -BinaryName fixture.exe -ArchiveType direct -ChecksumAssetPattern sums
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new()
		Mock Get-GitHubRelease {
			if ($AssetPattern -eq 'sums') { return @{ URL = 'https://example.test/sums'; Version = [TlcSemanticVersion]::new('1.0.0') } }
			return @{ Name = 'fixture.exe'; URL = 'https://example.test/fixture'; Version = [TlcSemanticVersion]::new('1.0.0') }
		}
		Mock Get-TlcGitHubReleaseAssetSha256 { $null }
		Mock Get-TlcRemoteSha256 { 'a' * 64 }
		Mock Invoke-TlcWebRequest { New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null; [IO.File]::WriteAllText($OutFile, 'fixture') }
		Install-TlcPackage
		Should -Invoke Get-TlcRemoteSha256 -Times 1

		Clear-TlcPackageScript
		Initialize-TlcGitHubCliPackage -Name nohash -CanonicalName nohash -Owner o -Repo r -AssetPattern asset -BinaryName nohash.exe -ArchiveType direct
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new()
		{ Install-TlcPackage } | Should -Throw '*no verified SHA-256*'
	}
}

Describe 'Verified Go builds and network cache behavior' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-network-$([Guid]::NewGuid().ToString('n'))"
		$script:OldPkgRoot = $env:TLC_PKG_ROOT
		$script:OldCacheRoot = $env:TLC_CACHE_ROOT
		$script:OldRequireVerified = $env:TLC_REQUIRE_VERIFIED_DOWNLOADS
		$env:TLC_PKG_ROOT = Join-Path $script:TempRoot 'pkg'
		$env:TLC_CACHE_ROOT = Join-Path $script:TempRoot 'cache'
		$env:TLC_REQUIRE_VERIFIED_DOWNLOADS = $null
		New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
	}

	AfterEach {
		$env:TLC_PKG_ROOT = $script:OldPkgRoot
		$env:TLC_CACHE_ROOT = $script:OldCacheRoot
		$env:TLC_REQUIRE_VERIFIED_DOWNLOADS = $script:OldRequireVerified
		Remove-Item Function:\go-fixture -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'builds a Go command after proving minimum module versions' {
		Mock Get-TlcApplicationPath { 'go-fixture' }
		Mock Invoke-TlcNativeCommand {
			if ($ArgumentList[0] -eq 'list') { return 'v1.3.0' }
			if ($ArgumentList[0] -eq 'build') {
				$index = [Array]::IndexOf([object[]]$ArgumentList, '-o')
				[IO.File]::WriteAllText([string]$ArgumentList[$index + 1], 'binary')
			}
		}
		$output = Join-Path $env:TLC_PKG_ROOT 'tool.exe'
		Invoke-TlcVerifiedGoCommandBuild -Module example.test/tool -Version v2.0.0 -Command ./cmd/tool -OutputPath $output -MinimumModules @{ 'example.test/dependency' = 'v1.2.0' } -BuildTags release -LdFlags '-s'
		Test-Path -LiteralPath $output -PathType Leaf | Should -BeTrue
		Should -Invoke Invoke-TlcNativeCommand -Times 4 -Exactly
	}

	It 'builds from checksum-verified module source with contained embedded files' {
		$sourceDir = Join-Path $script:TempRoot 'module-source'
		$embeddedDir = Join-Path $script:TempRoot 'embedded'
		New-Item -ItemType Directory -Path (Join-Path $sourceDir 'cmd/tool') -Force | Out-Null
		New-Item -ItemType Directory -Path $embeddedDir -Force | Out-Null
		[IO.File]::WriteAllText((Join-Path $sourceDir 'go.mod'), "module example.test/tool`n")
		[IO.File]::WriteAllText((Join-Path $sourceDir 'cmd/tool/main.go'), "package main`nfunc main() {}`n")
		[IO.File]::WriteAllText((Join-Path $embeddedDir 'manifest.yaml'), 'fixture')
		$script:EmbeddedFilesObserved = $false
		Mock Get-TlcApplicationPath { 'go-fixture' }
		Mock Invoke-TlcNativeCommand {
			if ($ArgumentList[0] -eq 'mod' -and $ArgumentList[1] -eq 'download') {
				return @{
					Path = 'example.test/tool'
					Version = 'v2.0.0'
					Sum = 'h1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
					GoModSum = 'h1:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='
					Dir = $sourceDir
				} | ConvertTo-Json
			}
			if ($ArgumentList[0] -eq 'list') { return 'v1.3.0' }
			if ($ArgumentList[0] -eq 'build') {
				$script:EmbeddedFilesObserved = Test-Path -LiteralPath (Join-Path (Get-Location) 'cmd/tool/manifests/manifest.yaml') -PathType Leaf
				$index = [Array]::IndexOf([object[]]$ArgumentList, '-o')
				[IO.File]::WriteAllText([string]$ArgumentList[$index + 1], 'binary')
			}
		}
		$output = Join-Path $env:TLC_PKG_ROOT 'tool.exe'
		Invoke-TlcVerifiedGoCommandBuild -Module example.test/tool -Version v2.0.0 `
			-Command example.test/tool/cmd/tool -OutputPath $output `
			-MinimumModules @{ 'example.test/dependency' = 'v1.2.0' } -UseModuleSource `
			-EmbeddedFilesPath $embeddedDir -EmbeddedFilesRelativeDestination 'cmd/tool/manifests'
		Test-Path -LiteralPath $output -PathType Leaf | Should -BeTrue
		$script:EmbeddedFilesObserved | Should -BeTrue
		Should -Invoke Invoke-TlcNativeCommand -Times 4 -Exactly
		Should -Invoke Invoke-TlcNativeCommand -Times 1 -Exactly -ParameterFilter {
			$ArgumentList[0] -eq 'build' -and $ArgumentList[-1] -eq './cmd/tool'
		}

		{
			Invoke-TlcVerifiedGoCommandBuild -Module example.test/tool -Version v2.0.0 `
				-Command example.test/tool/cmd/tool -OutputPath $output -UseModuleSource `
				-EmbeddedFilesPath $embeddedDir -EmbeddedFilesRelativeDestination '../outside'
		} | Should -Throw '*destination is unsafe*'
	}

	It 'builds from an exact verified Git source commit' {
		$expectedCommit = 'd' * 40
		Mock Get-TlcApplicationPath {
			if ($Name -eq 'git') { return 'git-fixture' }
			return 'go-fixture'
		}
		Mock Invoke-TlcNativeCommand {
			if ($FilePath -eq 'git-fixture' -and $ArgumentList[0] -eq 'clone') {
				$sourceRoot = [string]$ArgumentList[-1]
				New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'cmd/tool') -Force | Out-Null
				[IO.File]::WriteAllText((Join-Path $sourceRoot 'go.mod'), "module example.test/tool`n")
				[IO.File]::WriteAllText((Join-Path $sourceRoot 'cmd/tool/main.go'), "package main`nfunc main() {}`n")
				return
			}
			if ($FilePath -eq 'git-fixture' -and $ArgumentList[2] -eq 'rev-parse') { return $expectedCommit }
			if ($ArgumentList[0] -eq 'list') { return 'v1.3.0' }
			if ($ArgumentList[0] -eq 'build') {
				$index = [Array]::IndexOf([object[]]$ArgumentList, '-o')
				[IO.File]::WriteAllText([string]$ArgumentList[$index + 1], 'binary')
			}
		}
		$output = Join-Path $env:TLC_PKG_ROOT 'git-tool.exe'
		Invoke-TlcVerifiedGoCommandBuild -Module example.test/tool -Version v2.0.0 `
			-Command example.test/tool/cmd/tool -OutputPath $output `
			-MinimumModules @{ 'example.test/dependency' = 'v1.2.0' } -UseGitSource `
			-GitRepository 'https://github.com/owner/tool' -GitRef v2.0.0 -GitCommit $expectedCommit
		Test-Path -LiteralPath $output -PathType Leaf | Should -BeTrue
		Should -Invoke Invoke-TlcNativeCommand -Times 5 -Exactly
		Should -Invoke Invoke-TlcNativeCommand -Times 1 -Exactly -ParameterFilter {
			$FilePath -eq 'git-fixture' -and $ArgumentList[0] -eq 'clone' -and $ArgumentList[4] -eq 'v2.0.0'
		}

		{ Invoke-TlcVerifiedGoCommandBuild -Module example.test/tool -Version v2.0.0 -Command example.test/tool `
			-OutputPath $output -UseModuleSource -UseGitSource -GitRepository 'https://github.com/owner/tool' `
			-GitRef v2.0.0 -GitCommit $expectedCommit } | Should -Throw '*mutually exclusive*'
	}

	It 'rejects incomplete source-build inputs before invoking build tools' {
		$output = Join-Path $env:TLC_PKG_ROOT 'invalid-source.exe'
		$embeddedDir = Join-Path $env:TLC_PKG_ROOT 'embedded-input'
		New-Item -ItemType Directory -Path $embeddedDir -Force | Out-Null
		Mock Get-TlcApplicationPath { 'go-fixture' }

		{
			Invoke-TlcVerifiedGoCommandBuild -Module example.test/tool -Version v2.0.0 `
				-Command example.test/tool -OutputPath $output -UseGitSource `
				-GitRepository 'https://github.com/owner/tool'
		} | Should -Throw '*require repository, ref, and commit together*'

		{
			Invoke-TlcVerifiedGoCommandBuild -Module example.test/tool -Version v2.0.0 `
				-Command example.test/tool -OutputPath $output -EmbeddedFilesPath $embeddedDir
		} | Should -Throw '*path and relative destination must be supplied together*'

		{
			Invoke-TlcVerifiedGoCommandBuild -Module example.test/tool -Version v2.0.0 `
				-Command example.test/tool -OutputPath $output -EmbeddedFilesPath $embeddedDir `
				-EmbeddedFilesRelativeDestination 'manifests'
		} | Should -Throw '*require a source-tree build*'

		{
			Invoke-TlcVerifiedGoCommandBuild -Module example.test/tool -Version v2.0.0 `
				-Command example.test/tool -OutputPath $output -UseGitSource `
				-GitRepository 'http://example.test/owner/tool' -GitRef v2.0.0 -GitCommit ('d' * 40)
		} | Should -Throw '*not a supported GitHub HTTPS repository*'

		{
			Invoke-TlcVerifiedGoCommandBuild -Module example.test/tool -Version v2.0.0 `
				-Command example.test/tool -OutputPath $output -UseGitSource `
				-GitRepository 'https://github.com/owner/tool' -GitRef v2.0.0 -GitCommit 'not-a-sha'
		} | Should -Throw '*not a full SHA-1*'
	}

	It 'rejects a forbidden package in a verified Go command graph' {
		Mock Get-TlcApplicationPath { 'go-fixture' }
		Mock Invoke-TlcNativeCommand {
			if ($ArgumentList[0] -eq 'list' -and $ArgumentList[1] -eq '-deps') {
				return "example.test/safe$([Environment]::NewLine)example.test/forbidden/subpackage"
			}
		}
		$output = Join-Path $env:TLC_PKG_ROOT 'tool.exe'
		{
			Invoke-TlcVerifiedGoCommandBuild -Module example.test/tool -Version v2.0.0 -Command example.test/tool/cmd/tool `
				-OutputPath $output -ForbiddenPackagePrefixes @('example.test/forbidden')
		} | Should -Throw '*links forbidden package*example.test/forbidden/subpackage*'
		Should -Invoke Invoke-TlcNativeCommand -Times 3 -Exactly
		Should -Invoke Invoke-TlcNativeCommand -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'build' }
	}

	It 'downloads once, records a verified cache entry, and reuses it' {
		$payload = 'verified payload'
		$sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))).Replace('-', '').ToLowerInvariant()
		Mock Invoke-WebRequest {
			[IO.File]::WriteAllText($OutFile, $payload)
			[pscustomobject]@{ StatusCode = 200 }
		}
		$first = Join-Path $script:TempRoot 'one/tool.zip'
		$second = Join-Path $script:TempRoot 'two/tool.zip'
		Invoke-TlcWebRequest -Uri 'https://example.test/tool.zip' -OutFile $first -ExpectedSha256 $sha | Out-Null
		$result = Invoke-TlcWebRequest -Uri 'https://example.test/tool.zip' -OutFile $second -ExpectedSha256 $sha
		$result.FromCache | Should -BeTrue
		(Get-Content -LiteralPath $second -Raw) | Should -Be $payload
		Should -Invoke Invoke-WebRequest -Times 1
	}

	It 'enforces verified downloads and retries transient web failures' {
		$env:TLC_REQUIRE_VERIFIED_DOWNLOADS = 'true'
		$out = Join-Path $script:TempRoot 'download/file.bin'
		{ Invoke-TlcWebRequest -Uri 'https://example.test/file.bin' -OutFile $out } | Should -Throw '*verified downloads are required*'
		$env:TLC_REQUIRE_VERIFIED_DOWNLOADS = $null
		$script:WebAttempt = 0
		Mock Start-Sleep {}
		Mock Invoke-WebRequest {
			$script:WebAttempt++
			if ($script:WebAttempt -eq 1) { throw 'temporary' }
			[IO.File]::WriteAllText($OutFile, 'payload')
			[pscustomobject]@{ StatusCode = 200 }
		}
		Invoke-TlcWebRequest -Uri 'https://example.test/file.bin' -OutFile $out -MaxRetries 2 | Out-Null
		$script:WebAttempt | Should -Be 2
	}

	It 'paginates Docker tags and accepts either token response field' {
		$script:RegistryPage = 0
		Mock Invoke-TlcRestMethod {
			if ($Uri -like 'https://auth.docker.io/*') { return @{ access_token = 'token' } }
			$script:RegistryPage++
			if ($script:RegistryPage -eq 1) { return @{ tags = @(1..1000 | ForEach-Object { "tag$_" }) } }
			return @{ tags = @('last') }
		}
		$result = Get-DockerTags 'owner/repo'
		$result.tags.Count | Should -Be 1001
		$result.tags[-1] | Should -Be last
	}
}
