<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

Describe 'Container base digest refresh' {
	It 'updates every managed reference and detects stale pins in check mode' {
		$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-digest-$([Guid]::NewGuid().ToString('n'))"
		try {
			New-Item -ItemType Directory -Path (Join-Path $tempRoot 'src/pkgs') -Force | Out-Null
			$oldDigest = '1' * 64
			$newWindowsDigest = '2' * 64
			$newUbuntuDigest = '3' * 64
			[IO.File]::WriteAllText((Join-Path $tempRoot 'Dockerfile'), "FROM mcr.microsoft.com/windows/nanoserver:ltsc2022@sha256:$oldDigest")
			[IO.File]::WriteAllText((Join-Path $tempRoot 'src/huggingface-image.ps1'), "FROM ubuntu:22.04@sha256:$oldDigest")
			[IO.File]::WriteAllText((Join-Path $tempRoot 'src/pkgs/openai-gpt-oss-20b.ps1'), "FROM ubuntu:22.04@sha256:$oldDigest")
			$overrides = @{
				'mcr.microsoft.com/windows/nanoserver:ltsc2022' = "sha256:$newWindowsDigest"
				'ubuntu:22.04' = "sha256:$newUbuntuDigest"
			}
			{ & (Join-Path $PSScriptRoot 'update-container-base-digests.ps1') -RepositoryRoot $tempRoot -DigestOverride $overrides -Check } | Should -Throw '*stale*'
			& (Join-Path $PSScriptRoot 'update-container-base-digests.ps1') -RepositoryRoot $tempRoot -DigestOverride $overrides
			Get-Content -LiteralPath (Join-Path $tempRoot 'Dockerfile') -Raw | Should -Match "sha256:$newWindowsDigest"
			Get-Content -LiteralPath (Join-Path $tempRoot 'src/huggingface-image.ps1') -Raw | Should -Match "sha256:$newUbuntuDigest"
			{ & (Join-Path $PSScriptRoot 'update-container-base-digests.ps1') -RepositoryRoot $tempRoot -DigestOverride $overrides -Check } | Should -Not -Throw
		} finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
	}
}
