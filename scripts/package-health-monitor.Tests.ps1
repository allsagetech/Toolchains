<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

Describe 'Package health monitor' {
	BeforeEach {
		$script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
		New-Item -ItemType Directory -Path $script:root -Force | Out-Null
		$script:input = Join-Path $script:root 'health.json'
		$script:json = Join-Path $script:root 'report.json'
		$script:markdown = Join-Path $script:root 'report.md'
		$script:monitor = Join-Path $PSScriptRoot 'test-package-health-monitor.ps1'
		$script:now = [datetime]'2026-08-16T12:00:00Z'
	}

	It 'accepts fresh available signed-catalog results' {
		@([ordered]@{ Name='demo'; State='available'; Reason=''; Versions=@('1.0.0'); LastScannedAt='2026-08-16T10:00:00Z' }) |
			ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:input
		$report = & $script:monitor -InputPath $script:input -JsonOutputPath $script:json -MarkdownOutputPath $script:markdown -NowUtc $script:now
		$report.healthy | Should -BeTrue
		$report.problemCount | Should -Be 0
		Test-Path -LiteralPath $script:markdown | Should -BeTrue
	}

	It 'reports fallback, unsafe state, missing versions, stale scans, and duplicates' {
		@(
			[ordered]@{ Name='demo'; State='scan-blocked'; Reason='CVE-TEST'; Versions=@(); LastScannedAt='2026-08-01T00:00:00Z' },
			[ordered]@{ Name='demo'; State='available'; Reason=''; Versions=@('1.0.0'); LastScannedAt='2026-08-16T10:00:00Z' },
			[ordered]@{ Name='fallback'; State='available'; Reason='Live registry fallback; signed health metadata is unavailable.'; Versions=@('2.0.0'); LastScannedAt=$null }
		) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:input
		$report = & $script:monitor -InputPath $script:input -JsonOutputPath $script:json -MarkdownOutputPath $script:markdown -NowUtc $script:now
		$report.healthy | Should -BeFalse
		$report.problems.category | Should -Contain 'Signature'
		$report.problems.category | Should -Contain 'State'
		$report.problems.category | Should -Contain 'Versions'
		$report.problems.category | Should -Contain 'ScanFreshness'
		$report.problems.category | Should -Contain 'Schema'
		{ & $script:monitor -InputPath $script:input -JsonOutputPath $script:json -MarkdownOutputPath $script:markdown -NowUtc $script:now -Strict } | Should -Throw '*monitor found*'
	}
}
