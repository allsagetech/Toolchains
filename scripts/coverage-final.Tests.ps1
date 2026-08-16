<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

BeforeAll {
	$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
	. (Join-Path $script:RepoRoot 'src/main.ps1')
}

Describe 'Subprocess and bootstrap helpers' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-subprocess-$([Guid]::NewGuid().ToString('n'))"
		$script:OldPkgRoot = $env:TLC_PKG_ROOT
		$env:TLC_PKG_ROOT = Join-Path $script:TempRoot 'pkg'
		New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
	}

	AfterEach {
		$env:TLC_PKG_ROOT = $script:OldPkgRoot
		$script:Tlc7ZipExecutable = $null
		Remove-Item Function:\docker -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'runs a Hugging Face snapshot subprocess with progress and restores environment' {
		$oldRepo = $env:TLC_HF_REPO_ID
		$oldRevision = $env:TLC_HF_REVISION
		$oldPatterns = $env:TLC_HF_ALLOW_PATTERNS
		$oldCache = $env:HF_HUB_CACHE
		try {
			$env:TLC_HF_REPO_ID = 'original/repo'
			$env:TLC_HF_REVISION = 'original-revision'
			$env:TLC_HF_ALLOW_PATTERNS = 'original-patterns'
			$env:HF_HUB_CACHE = 'original-cache'
			Mock Start-Sleep {}
			Mock Start-Process {
				[IO.File]::WriteAllText($RedirectStandardOutput, '/cache/models--owner--model')
				[IO.File]::WriteAllText($RedirectStandardError, 'download progress')
				$process = [pscustomobject]@{ HasExited = $false; ExitCode = 0; RefreshCount = 0 }
				$process | Add-Member -MemberType ScriptMethod -Name Refresh -Value {
					$this.RefreshCount++
					if ($this.RefreshCount -ge 2) { $this.HasExited = $true }
				}
				return $process
			}
			Invoke-TlcHfSnapshotDownload -PythonPath python -Repo owner/model -CacheDir cache -Revision abc -AllowPatterns @('*.json', '*.safetensors')
			$env:TLC_HF_REPO_ID | Should -Be 'original/repo'
			$env:TLC_HF_REVISION | Should -Be 'original-revision'
			$env:TLC_HF_ALLOW_PATTERNS | Should -Be 'original-patterns'
			$env:HF_HUB_CACHE | Should -Be 'original-cache'
			Should -Invoke Start-Sleep -Times 2
		} finally {
			$env:TLC_HF_REPO_ID = $oldRepo
			$env:TLC_HF_REVISION = $oldRevision
			$env:TLC_HF_ALLOW_PATTERNS = $oldPatterns
			$env:HF_HUB_CACHE = $oldCache
		}
	}

	It 'reports a failed Hugging Face snapshot subprocess' {
		Mock Start-Process { [pscustomobject]@{ HasExited = $true; ExitCode = 9 } }
		{ Invoke-TlcHfSnapshotDownload -PythonPath python -Repo owner/model -CacheDir cache } | Should -Throw '*failed with exit code 9*'
	}

	It 'bootstraps 7-Zip once and then reuses the verified executable' {
		Mock Invoke-TlcWebRequest {}
		Mock Start-Process {
			$destination = [string](@($ArgumentList) | Where-Object { $_ -like '/D=*' } | Select-Object -First 1)
			$destination = $destination.Substring(3)
			New-Item -ItemType Directory -Path $destination -Force | Out-Null
			[IO.File]::WriteAllText((Join-Path $destination '7z.exe'), '7zip')
			[pscustomobject]@{ ExitCode = 0 }
		}
		$first = Get-Tlc7ZipExecutable
		$second = Get-Tlc7ZipExecutable
		$first | Should -Be $second
		Test-Path -LiteralPath $first -PathType Leaf | Should -BeTrue
		Should -Invoke Start-Process -Times 1
	}
}

Describe 'GitHub metadata fallbacks' {
	It 'uses the latest release endpoint when it has the requested stable asset' {
		Mock Invoke-TlcRestMethod {
			[pscustomobject]@{
				tag_name = 'v3.2.1'
				prerelease = $false
				assets = @([pscustomobject]@{ name = 'tool.zip'; browser_download_url = 'https://example.test/tool.zip' })
			}
		}
		$result = Get-GitHubRelease -Owner owner -Repo repo -AssetPattern '^tool\.zip$' -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
		$result.Version.ToString() | Should -Be '3.2.1'
	}

	It 'falls back to paginated releases when latest lookup fails' {
		$script:ReleaseRequest = 0
		Mock Invoke-TlcRestMethod {
			$script:ReleaseRequest++
			if ($Uri -like '*/releases/latest') { throw 'latest unavailable' }
			if ($Uri -like '*page=1') {
				return ,([pscustomobject]@{
					tag_name = 'v2.0.0'
					prerelease = $false
					assets = @([pscustomobject]@{ name = 'tool.zip'; browser_download_url = 'https://example.test/tool.zip' })
				})
			}
			return @()
		}
		$result = Get-GitHubRelease -Owner owner -Repo repo -AssetPattern '^tool\.zip$' -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
		$result.Version.ToString() | Should -Be '2.0.0'
		$script:ReleaseRequest | Should -Be 2
	}

	It 'pages tags and returns the newest semantic version' {
		$script:TagPage = 0
		Mock Invoke-TlcRestMethod {
			$script:TagPage++
			if ($script:TagPage -eq 1) { return @([pscustomobject]@{ name = 'v1.0.0' }, [pscustomobject]@{ name = 'v1.5.0' }) }
			return @()
		}
		$result = Get-GitHubTag -Owner owner -Repo repo -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
		$result.Name | Should -Be 'v1.5.0'
		$result.Version.ToString() | Should -Be '1.5.0'
	}

	It 'installs a Node distribution with its official checksum document' {
		$oldTemp = $env:Temp
		$env:Temp = [IO.Path]::GetTempPath().TrimEnd('\', '/')
		try {
			Mock Get-TlcRemoteSha256 { 'a' * 64 }
			Mock Invoke-TlcWebRequest {}
			Mock Expand-Archive {}
			Install-BuildTool -AssetName node-v22.1.0-win-x64.zip -AssetURL 'https://nodejs.org/dist/v22.1.0/node-v22.1.0-win-x64.zip' -ToolDir ([IO.Path]::GetTempPath())
			Should -Invoke Get-TlcRemoteSha256 -Times 1 -ParameterFilter { $AssetName -eq 'node-v22.1.0-win-x64.zip' }
			Should -Invoke Invoke-TlcWebRequest -Times 1 -ParameterFilter { $ExpectedSha256 -eq ('a' * 64) }
		} finally { $env:Temp = $oldTemp }
	}
}

Describe 'Workflow matrix and signing behavior' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-matrix-$([Guid]::NewGuid().ToString('n'))"
		$script:OldLocation = (Get-Location).Path
		$script:OldRefName = $env:GITHUB_REF_NAME
		$script:OldSign = $env:TLC_COSIGN_SIGN
		$script:OldKey = $env:TLC_COSIGN_KEY
		New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'pkgs') -Force | Out-Null
		[IO.File]::WriteAllText((Join-Path $script:TempRoot 'pkgs/fixture.ps1'), '# fixture')
		Set-Location $script:TempRoot
	}

	AfterEach {
		Set-Location $script:OldLocation
		$env:GITHUB_REF_NAME = $script:OldRefName
		$env:TLC_COSIGN_SIGN = $script:OldSign
		$env:TLC_COSIGN_KEY = $script:OldKey
		Remove-Item Function:\docker -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'generates a complete publish matrix and honors a package ref selector' {
		Set-Location $script:TempRoot
		Mock Get-DockerTags { @{ tags = @() } }
		Mock Read-TlcPackageDescriptors {
			@([pscustomobject]@{
				Path = [string]$Path[0]
				Config = @{ Name = 'fixture'; Version = '1.0.0'; Platform = 'linux/amd64'; RunsOn = 'ubuntu-22.04'; Tier = 'tooling' }
			})
		}
		Save-WorkflowMatrix
		$matrix = Get-Content -LiteralPath '.matrix' -Raw | ConvertFrom-Json
		@($matrix.include).Count | Should -Be 1
		$matrix.include[0].pkg_root | Should -Be '/mnt/toolchains-pkg'
		$matrix.include[0].publish_eligible | Should -BeTrue

		$env:GITHUB_REF_NAME = 'refs/heads/fixture-1.0.0'
		Save-WorkflowMatrix
		@((Get-Content -LiteralPath '.matrix' -Raw | ConvertFrom-Json).include).Count | Should -Be 1
	}

	It 'signs immutable Docker digests using the configured key' {
		$cosignPath = Join-Path $script:TempRoot 'cosign.ps1'
		[IO.File]::WriteAllText($cosignPath, '$global:LASTEXITCODE = 0')
		$env:TLC_COSIGN_SIGN = 'true'
		$env:TLC_COSIGN_KEY = 'test-key'
		function global:docker { $global:LASTEXITCODE = 0; 'example.test/tool@sha256:' + ('a' * 64) }
		Mock Get-Command { [pscustomobject]@{ Source = $cosignPath } } -ParameterFilter { $Name -eq 'cosign' }
		{ Invoke-CosignSignImage 'example.test/tool:1' } | Should -Not -Throw
	}

	It 'fails signing when cosign or an immutable digest is unavailable' {
		$env:TLC_COSIGN_SIGN = 'true'
		Mock Get-Command { $null } -ParameterFilter { $Name -eq 'cosign' }
		{ Invoke-CosignSignImage tag } | Should -Throw '*not available on PATH*'

		$cosignPath = Join-Path $script:TempRoot 'cosign.ps1'
		[IO.File]::WriteAllText($cosignPath, '$global:LASTEXITCODE = 0')
		Mock Get-Command { [pscustomobject]@{ Source = $cosignPath } } -ParameterFilter { $Name -eq 'cosign' }
		function global:docker { $global:LASTEXITCODE = 0 }
		{ Invoke-CosignSignImage tag } | Should -Throw '*no immutable RepoDigest*'
	}
}
