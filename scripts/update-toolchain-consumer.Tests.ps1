<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

Describe 'Toolchain consumer promotion updater' {
	BeforeEach {
		$script:fixtureRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
		New-Item -ItemType Directory -Path $script:fixtureRoot -Force | Out-Null
		'{"schemaVersion":1,"repository":"allsagetech/toolchain","version":"1.0.0","ref":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' |
			Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'toolchain-consumer.json')
		$script:targetRef = 'b' * 40
		$script:updater = Join-Path $PSScriptRoot 'update-toolchain-consumer.ps1'
	}

	It 'updates the single-source consumer manifest' {
		$result = & $script:updater -Root $script:fixtureRoot -Version v2.3.3 -Ref $script:targetRef
		$result.Changed | Should -BeTrue
		$manifest = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'toolchain-consumer.json') -Raw | ConvertFrom-Json
		$manifest.version | Should -Be '2.3.3'
		$manifest.ref | Should -Be $script:targetRef
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

	It 'rejects invalid inputs' {
		{ & $script:updater -Root $script:fixtureRoot -Version nope -Ref $script:targetRef } |
			Should -Throw '*Version must*'
		{ & $script:updater -Root $script:fixtureRoot -Version 2.3.3 -Ref short } |
			Should -Throw '*40-character*'
	}

	It 'rejects missing roots' {
		{ & $script:updater -Root (Join-Path $TestDrive 'missing') -Version 2.3.3 -Ref $script:targetRef } |
			Should -Throw '*root does not exist*'
	}
}
