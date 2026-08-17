<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

BeforeAll {
	$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
	. (Join-Path $script:RepoRoot 'src/main.ps1')
}

Describe 'Hugging Face layered image helpers' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-hf-image-$([Guid]::NewGuid().ToString('n'))"
		$script:OldPkgRoot = $env:TLC_PKG_ROOT
		$env:TLC_PKG_ROOT = $script:TempRoot
		New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
		$global:TlcPackageConfig = @{ Name = 'owner/model'; Version = '1.2.3' }
	}

	AfterEach {
		$env:TLC_PKG_ROOT = $script:OldPkgRoot
		Remove-Variable TlcPackageConfig -Scope Global -Force -ErrorAction SilentlyContinue
		Remove-Item Function:\docker -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'writes one Docker layer per model blob and rebuilds from its manifest' {
		[IO.File]::WriteAllText((Join-Path $script:TempRoot '.tlc'), '{}')
		[IO.File]::WriteAllText((Join-Path $script:TempRoot 'official-models.manifest.json'), '{"models":[{"cache_slug":"models--owner--model"}]}')
		$modelRoot = Join-Path $script:TempRoot 'cache/hf-cache/models--owner--model'
		New-Item -ItemType Directory -Path (Join-Path $modelRoot 'blobs') -Force | Out-Null
		New-Item -ItemType Directory -Path (Join-Path $modelRoot 'refs') -Force | Out-Null
		New-Item -ItemType Directory -Path (Join-Path $modelRoot 'snapshots/abc') -Force | Out-Null
		[IO.File]::WriteAllText((Join-Path $modelRoot 'blobs/a'), 'a')
		[IO.File]::WriteAllText((Join-Path $modelRoot 'blobs/b'), 'b')

		$dockerfile = Write-HfModelLayeredDockerfile -PkgRoot $script:TempRoot -CacheRoot (Join-Path $script:TempRoot 'cache/hf-cache') -CacheSlug 'models--owner--model'
		$content = Get-Content -LiteralPath $dockerfile -Raw
		$content | Should -Match 'COPY.*blobs/a'
		$content | Should -Match 'COPY.*blobs/b'
		(Get-Content -LiteralPath (Join-Path $script:TempRoot '.dockerignore') -Raw) | Should -Match 'hf-xet'

		Remove-Item -LiteralPath $dockerfile
		Mock Invoke-HfModelLayeredDockerBuild {}
		Invoke-HfModelCustomDockerBuild 'example.test/model:1'
		Should -Invoke Invoke-HfModelLayeredDockerBuild -Times 1 -ParameterFilter { $Tag -eq 'example.test/model:1' }
	}

	It 'rejects incomplete model caches and manifests' {
		$cache = Join-Path $script:TempRoot 'cache'
		{ Write-HfModelLayeredDockerfile -PkgRoot $script:TempRoot -CacheRoot $cache -CacheSlug missing } | Should -Throw '*cache entry not found*'
		New-Item -ItemType Directory -Path (Join-Path $cache 'missing') -Force | Out-Null
		{ Write-HfModelLayeredDockerfile -PkgRoot $script:TempRoot -CacheRoot $cache -CacheSlug missing } | Should -Throw '*blobs directory not found*'
		New-Item -ItemType Directory -Path (Join-Path $cache 'missing/blobs') -Force | Out-Null
		{ Write-HfModelLayeredDockerfile -PkgRoot $script:TempRoot -CacheRoot $cache -CacheSlug missing } | Should -Throw '*No model blobs*'
		{ Invoke-HfModelCustomDockerBuild 'tag' } | Should -Throw '*manifest not found*'
		[IO.File]::WriteAllText((Join-Path $script:TempRoot 'official-models.manifest.json'), '{"models":[{}]}')
		{ Invoke-HfModelCustomDockerBuild 'tag' } | Should -Throw '*missing cache_slug*'
	}

	It 'builds a labeled image and fails closed on a Docker error' {
		[IO.File]::WriteAllText((Join-Path $script:TempRoot '.tlc'), '{"env":{}}')
		$dockerfile = Join-Path $script:TempRoot 'Dockerfile.hf-model-owner-model'
		[IO.File]::WriteAllText($dockerfile, 'FROM scratch')
		Mock Get-TlcApplicationPath { 'docker' } -ParameterFilter { $Name -eq 'docker' }
		Mock Invoke-TlcNativeCommand {}
		{ Invoke-HfModelLayeredDockerBuild -Tag 'example.test/model:1' -DockerfilePath $dockerfile } | Should -Not -Throw
		Should -Invoke Invoke-TlcNativeCommand -Times 1 -Exactly -ParameterFilter {
			$FilePath -eq 'docker' -and @($ArgumentList)[0] -eq 'build' -and
			$FailureMessage -eq 'docker build failed for example.test/model:1'
		}
		Mock Invoke-TlcNativeCommand { throw 'docker build failed for example.test/model:1 (exit code 7).' }
		{ Invoke-HfModelLayeredDockerBuild -Tag 'example.test/model:1' -DockerfilePath $dockerfile } | Should -Throw '*docker build failed*7*'
		Remove-Item -LiteralPath $dockerfile
		{ Invoke-HfModelLayeredDockerBuild -Tag 'tag' -DockerfilePath $dockerfile } | Should -Throw '*Layered Dockerfile not found*'
	}

	It 'handles Windows and token-gated model packages without downloading' {
		$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new('1.2.3')
		Mock Test-TlcHostIsWindows { $true }
		Install-HfModelPackage -Model @{ Repo = 'owner/model' }
		$global:TlcPackageConfig.Version | Should -Be '1.2.3'
		$global:TlcPackageConfig.UpToDate | Should -BeTrue

		Mock Test-TlcHostIsWindows { $false }
		$oldToken = $env:HF_TOKEN
		try {
			$env:HF_TOKEN = $null
			Install-HfModelPackage -Model @{ Repo = 'owner/private'; RequiresHfToken = $true }
			$global:TlcPackageConfig.UpToDate | Should -BeTrue
		} finally { $env:HF_TOKEN = $oldToken }
		{ Install-HfModelPackage -Model @{} } | Should -Throw '*Model.Repo*'
	}

	It 'installs and validates a layered model package through checked subprocesses' {
		$environmentNames = @(
			'HF_HOME', 'HF_HUB_CACHE', 'TRANSFORMERS_CACHE', 'HF_XET_CACHE',
			'HF_XET_HIGH_PERFORMANCE', 'HF_HUB_DOWNLOAD_TIMEOUT', 'HF_HUB_ETAG_TIMEOUT'
		)
		$oldEnvironment = @{}
		foreach ($name in $environmentNames) {
			$oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
		}
		try {
			$env:HF_HOME = 'prior-home'
			$env:HF_HUB_CACHE = 'prior-hub'
			$env:TRANSFORMERS_CACHE = 'prior-transformers'
			$env:HF_XET_CACHE = 'prior-xet'
			$env:HF_XET_HIGH_PERFORMANCE = 'prior-performance'
			$env:HF_HUB_DOWNLOAD_TIMEOUT = '321'
			$env:HF_HUB_ETAG_TIMEOUT = '23'
			$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new('1.0.0')

			Mock Test-TlcHostIsWindows { $false }
			Mock Get-Command { [pscustomobject]@{ Source = 'python3' } } -ParameterFilter { $Name -eq 'python3' }
			Mock Get-TlcHfHeaders { @{} }
			Mock Get-TlcHfModelVersion { '2.3.4' }
			Mock Invoke-TlcNativeCommand {
				if (@($ArgumentList) -contains 'venv') {
					$venvRoot = [string]$ArgumentList[-1]
					New-Item -ItemType Directory -Path (Join-Path $venvRoot 'bin') -Force | Out-Null
					[IO.File]::WriteAllText((Join-Path $venvRoot 'bin/python'), 'fixture')
				}
			}
			Mock Invoke-TlcHfSnapshotDownload {
				$modelRoot = Join-Path $CacheDir 'models--owner--model'
				New-Item -ItemType Directory -Path (Join-Path $modelRoot 'blobs') -Force | Out-Null
				New-Item -ItemType Directory -Path (Join-Path $modelRoot 'refs') -Force | Out-Null
				New-Item -ItemType Directory -Path (Join-Path $modelRoot 'snapshots/main') -Force | Out-Null
				[IO.File]::WriteAllText((Join-Path $modelRoot 'blobs/model'), 'model')
			}

			Install-HfModelPackage -Model @{
				Repo = 'owner/model'
				Alias = 'model-alias'
				SourceModel = 'owner/source'
				OfficialModel = 'owner/official'
				CacheSlug = 'models--owner--model'
				Revision = 'main'
				AllowPatterns = @('*.json', '*.safetensors')
			}

			$global:TlcPackageConfig.Version | Should -BeExactly '2.3.4'
			$global:TlcPackageConfig.UpToDate | Should -BeFalse
			Test-Path -LiteralPath (Join-Path $script:TempRoot '.tlc') | Should -BeTrue
			Test-Path -LiteralPath (Join-Path $script:TempRoot 'Dockerfile.hf-model-owner-model') | Should -BeTrue
			Test-Path -LiteralPath (Join-Path $script:TempRoot '.hf-tools') | Should -BeFalse
			$manifest = Get-Content -LiteralPath (Join-Path $script:TempRoot 'official-models.manifest.json') -Raw | ConvertFrom-Json
			$manifest.models[0].alias | Should -BeExactly 'model-alias'
			$manifest.models[0].source_model | Should -BeExactly 'owner/source'
			Should -Invoke Invoke-TlcNativeCommand -Times 3 -Exactly
			Should -Invoke Invoke-TlcHfSnapshotDownload -Times 1 -Exactly -ParameterFilter {
				$Revision -eq 'main' -and @($AllowPatterns).Count -eq 2
			}

			Test-HfModelPackageInstall -Repo 'owner/model' -CacheSlug 'models--owner--model'
			$env:HF_HOME | Should -BeExactly 'prior-home'
			$env:HF_HUB_CACHE | Should -BeExactly 'prior-hub'
		} finally {
			foreach ($name in $environmentNames) {
				if ($null -eq $oldEnvironment[$name]) {
					Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
				} else {
					Set-Item -LiteralPath "Env:$name" -Value $oldEnvironment[$name]
				}
			}
		}
	}
}

Describe 'Download integrity edge cases' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-integrity-$([Guid]::NewGuid().ToString('n'))"
		New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
	}

	AfterEach {
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'rejects missing, empty, malformed, mismatched, and failed custom verification' {
		$file = Join-Path $script:TempRoot 'asset.bin'
		{ Assert-TlcDownloadedFile -Path $file -Uri 'https://example.test/a' } | Should -Throw '*did not create*'
		[IO.File]::WriteAllBytes($file, [byte[]]@())
		{ Assert-TlcDownloadedFile -Path $file -Uri 'https://example.test/a' } | Should -Throw '*empty*'
		[IO.File]::WriteAllText($file, 'content')
		{ Assert-TlcDownloadedFile -Path $file -Uri 'u' -ExpectedSha256 nope } | Should -Throw '*invalid expected SHA-256*'
		{ Assert-TlcDownloadedFile -Path $file -Uri 'u' -ExpectedHash xyz } | Should -Throw '*invalid expected SHA256*'
		{ Assert-TlcDownloadedFile -Path $file -Uri 'u' -SignatureVerifier { $false } } | Should -Throw '*signature verification failed*'
		{ Assert-TlcDownloadedFile -Path $file -Uri 'u' -SignatureVerifier { $true } } | Should -Not -Throw
	}

	It 'parses byte checksum documents and reports absent hashes' {
		$sha384 = 'a' * 96
		Mock Invoke-TlcWebRequest { [pscustomobject]@{ Content = [Text.Encoding]::UTF8.GetBytes("$sha384 *dir/asset.tgz") } }
		Get-TlcRemoteHash -ChecksumUri 'https://example.test/sums' -AssetName 'asset.tgz' -Algorithm SHA384 | Should -Be $sha384
		Get-TlcRemoteHash -ChecksumUri 'https://example.test/sums' -Algorithm SHA384 | Should -Be $sha384
		Mock Invoke-TlcWebRequest { [pscustomobject]@{ Content = ' ' } }
		{ Get-TlcRemoteHash -ChecksumUri u } | Should -Throw '*empty*'
		Mock Invoke-TlcWebRequest { [pscustomobject]@{ Content = 'no hash here' } }
		{ Get-TlcRemoteHash -ChecksumUri u -AssetName a } | Should -Throw '*was not found*'
		{ Get-TlcRemoteHash -ChecksumUri u } | Should -Throw '*was not found*'
	}

	It 'uses GitHub release digests, companion checksums, and safe null fallbacks' {
		$sha = 'b' * 64
		Mock Invoke-TlcRestMethod { [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'tool.zip'; digest = "sha256:$sha" }) } }
		Get-TlcGitHubReleaseAssetSha256 -Uri 'https://github.com/o/r/releases/download/v1/tool.zip' | Should -Be $sha
		Get-TlcGitHubReleaseAssetSha256 -Uri 'https://example.test/tool.zip' | Should -BeNullOrEmpty
		Get-TlcGitHubReleaseAssetSha256 -Uri 'https://github.com/o/r/archive/v1.zip' | Should -BeNullOrEmpty

		Mock Invoke-TlcRestMethod { [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'tool.zip.sha256'; browser_download_url = 'https://example.test/sum' }) } }
		Mock Get-TlcRemoteSha256 { $sha }
		Get-TlcGitHubReleaseAssetSha256 -Uri 'https://github.com/o/r/releases/download/v1/tool.zip' | Should -Be $sha
		Should -Invoke Get-TlcRemoteSha256 -Times 1

		Mock Invoke-TlcRestMethod { [pscustomobject]@{ assets = @() } }
		Get-TlcGitHubReleaseAssetSha256 -Uri 'https://github.com/o/r/releases/download/v1/tool.zip' | Should -BeNullOrEmpty
	}
}

Describe 'Docker publication behavior' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-docker-$([Guid]::NewGuid().ToString('n'))"
		$script:OldPkgRoot = $env:TLC_PKG_ROOT
		$script:OldRepo = $env:TLC_DOCKER_REPO
		$script:OldSign = $env:TLC_COSIGN_SIGN
		$script:OldKey = $env:TLC_COSIGN_KEY
		$env:TLC_PKG_ROOT = $script:TempRoot
		$env:TLC_DOCKER_REPO = 'example.test/toolchains'
		$env:TLC_COSIGN_SIGN = $null
		$env:TLC_COSIGN_KEY = $null
		New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
		[IO.File]::WriteAllText((Join-Path $script:TempRoot '.tlc'), '{"env":{}}')
	}

	AfterEach {
		$env:TLC_PKG_ROOT = $script:OldPkgRoot
		$env:TLC_DOCKER_REPO = $script:OldRepo
		$env:TLC_COSIGN_SIGN = $script:OldSign
		$env:TLC_COSIGN_KEY = $script:OldKey
		Remove-Item Function:\docker -Force -ErrorAction SilentlyContinue
		Remove-Item Function:\Invoke-CustomDockerBuild -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'builds using the repository Dockerfile and verifies every required label' {
		$script:DockerCalls = [Collections.Generic.List[string]]::new()
		function global:docker {
			$call = $args -join ' '
			$script:DockerCalls.Add($call)
			$global:LASTEXITCODE = 0
			if ($call -like 'build *') {
				Write-Error 'BuildKit progress on stderr' -ErrorAction Continue
			}
			if ($call -like 'image inspect*Config.Labels*') {
				return '{"io.allsagetech.toolchain.specVersion":"1","io.allsagetech.toolchain.packageName":"fixture","io.allsagetech.toolchain.packageVersion":"1.2.3","io.allsagetech.toolchain.tlcPath":"/.tlc","io.allsagetech.toolchain.tlcSha256":"' + ((Get-FileHash -LiteralPath (Join-Path $script:TempRoot '.tlc') -Algorithm SHA256).Hash.ToLowerInvariant()) + '","toolchain.tlcPath":"/.tlc","toolchain.tlcSha256":"' + ((Get-FileHash -LiteralPath (Join-Path $script:TempRoot '.tlc') -Algorithm SHA256).Hash.ToLowerInvariant()) + '"}'
			}
		}
		$buildErrors = @()
		Invoke-DockerBuild -Tag 'example.test/t:1' -PkgName fixture -PkgVersion 1.2.3 -DockerfileName Dockerfile -Config @{} -ErrorVariable +buildErrors
		(($buildErrors | ForEach-Object { $_.ToString() }) -join "`n") | Should -Not -Match 'BuildKit progress on stderr'
		($script:DockerCalls -join "`n") | Should -Match '^build '
		Test-Path -LiteralPath (Join-Path $script:TempRoot '.dockerignore') | Should -BeTrue
		Set-TlcPackageDockerignore -PkgRoot $script:TempRoot
		(@(Get-Content (Join-Path $script:TempRoot '.dockerignore')) | Where-Object { $_ -eq 'cache' }).Count | Should -Be 1
	}

	It 'supports a custom builder' {
		function global:Invoke-CustomDockerBuild { $global:LASTEXITCODE = 0 }
		Mock Assert-TlcBuiltImageContract {}
		$config = @{}
		Invoke-DockerBuild -Tag tag -PkgName custom -PkgVersion 2.0.0 -Config $config
		$config.Name | Should -Be custom
		Should -Invoke Assert-TlcBuiltImageContract -Times 1
	}

	It 'rejects missing image labels and failed image inspection' {
		function global:docker { $global:LASTEXITCODE = 0; '{}' }
		{ Assert-TlcBuiltImageContract -Tag tag -ExpectedLabels @('required=value') } | Should -Throw '*missing required label*'
		function global:docker { $global:LASTEXITCODE = 1 }
		{ Assert-TlcBuiltImageContract -Tag tag -ExpectedLabels @('required=value') } | Should -Throw '*could not inspect*'
	}

	It 'pushes new tags, skips existing unsigned tags, and refuses ambiguous signed tags' {
		Mock Assert-DockerDaemonAvailable {}
		Mock Invoke-DockerBuild {}
		Mock Invoke-CosignSignImage {}
		Mock Test-DockerTagExists { $false }
		function global:docker { $global:LASTEXITCODE = 0; if (($args -join ' ') -like 'image inspect*Size*') { '1073741824' } }
		Invoke-DockerPush -Name fixture -Version '1.2.3+4' -Config @{ Dockerfile = 'Dockerfile.linux' }
		Should -Invoke Invoke-DockerBuild -Times 1 -ParameterFilter { $Tag -eq 'example.test/toolchains:fixture-1.2.3_4' -and $DockerfileName -eq 'Dockerfile.linux' }
		Should -Invoke Invoke-CosignSignImage -Times 1

		Mock Test-DockerTagExists { $true }
		Invoke-DockerPush -Name fixture -Version 1.2.3 -Config @{}
		$env:TLC_COSIGN_SIGN = 'true'
		{ Invoke-DockerPush -Name fixture -Version 1.2.3 -Config @{} } | Should -Throw '*refusing to skip*'
	}

	It 'checks tag, daemon, repository, signing, and runner policy branches' {
		function global:docker { $global:LASTEXITCODE = 0 }
		Test-DockerTagExists tag | Should -BeTrue
		function global:docker { throw 'offline' }
		Test-DockerTagExists tag | Should -BeFalse

		Get-TlcDockerRepo | Should -Be 'example.test/toolchains'
		$env:TLC_DOCKER_REPO = $null
		Get-TlcDockerRepo | Should -Be 'allsagetech/toolchains'
		$env:COSIGN_KEY = 'key'
		try { Test-CosignSigningEnabled | Should -BeTrue } finally { $env:COSIGN_KEY = $null }
		Test-CosignSigningEnabled | Should -BeFalse
		Test-TlcRunsOnUbuntu -RunsOn @('self-hosted', 'ubuntu-22.04') | Should -BeTrue
		Get-TlcPkgRootForRunner -RunsOn 'ubuntu-22.04' | Should -Be '/mnt/toolchains-pkg'
		Get-TlcCachePathForRunner -RunsOn 'windows-2022' | Should -Be 'D:\pkg\cache'
	}
}
