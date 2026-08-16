<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

Describe 'Toolchain consumer promotion updater' {
	BeforeEach {
		$script:fixtureRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
		New-Item -ItemType Directory -Path (Join-Path $script:fixtureRoot '.github/workflows') -Force | Out-Null
		'{"schemaVersion":1,"repository":"allsagetech/toolchain","version":"1.0.0","ref":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' |
			Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'toolchain-consumer.json')
		foreach ($name in @('build-push.yml','certify-published.yml')) {
			"env:`n  TOOLCHAIN_REF: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`njobs: {}`n" |
				Set-Content -LiteralPath (Join-Path $script:fixtureRoot ".github/workflows/$name")
		}
		$script:targetRef = 'b' * 40
		$script:updater = Join-Path $PSScriptRoot 'update-toolchain-consumer.ps1'
	}

	It 'updates the manifest and every workflow pin atomically' {
		$result = & $script:updater -Root $script:fixtureRoot -Version v2.3.3 -Ref $script:targetRef
		$result.Changed | Should -BeTrue
		$manifest = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'toolchain-consumer.json') -Raw | ConvertFrom-Json
		$manifest.version | Should -Be '2.3.3'
		$manifest.ref | Should -Be $script:targetRef
		foreach ($name in @('build-push.yml','certify-published.yml')) {
			(Get-Content -LiteralPath (Join-Path $script:fixtureRoot ".github/workflows/$name") -Raw) | Should -Match $script:targetRef
		}
	}

	It 'is idempotent and passes check mode when current' {
		$null = & $script:updater -Root $script:fixtureRoot -Version 2.3.3 -Ref $script:targetRef
		$result = & $script:updater -Root $script:fixtureRoot -Version 2.3.3 -Ref $script:targetRef -Check
		$result.Changed | Should -BeFalse
		$result.Check | Should -BeTrue
	}

	It 'fails check mode for stale state' {
		{ & $script:updater -Root $script:fixtureRoot -Version 2.3.3 -Ref $script:targetRef -Check } |
			Should -Throw '*promotion is stale*'
	}

	It 'rejects ambiguous workflow pins and invalid inputs' {
		Add-Content -LiteralPath (Join-Path $script:fixtureRoot '.github/workflows/build-push.yml') -Value "  TOOLCHAIN_REF: $('c' * 40)"
		{ & $script:updater -Root $script:fixtureRoot -Version 2.3.3 -Ref $script:targetRef } |
			Should -Throw '*exactly one*'
		{ & $script:updater -Root $script:fixtureRoot -Version nope -Ref $script:targetRef } |
			Should -Throw '*Version must*'
		{ & $script:updater -Root $script:fixtureRoot -Version 2.3.3 -Ref short } |
			Should -Throw '*40-character*'
	}

	It 'rejects missing roots and workflows' {
		{ & $script:updater -Root (Join-Path $TestDrive 'missing') -Version 2.3.3 -Ref $script:targetRef } |
			Should -Throw '*root does not exist*'
		Remove-Item -LiteralPath (Join-Path $script:fixtureRoot '.github/workflows/certify-published.yml')
		{ & $script:updater -Root $script:fixtureRoot -Version 2.3.3 -Ref $script:targetRef } |
			Should -Throw '*Required workflow*'
	}
}
