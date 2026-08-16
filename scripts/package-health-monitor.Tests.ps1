<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

Describe 'Package health monitor' {
	BeforeEach {
		$script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
		New-Item -ItemType Directory -Path $script:root -Force | Out-Null
		$script:input = Join-Path $script:root 'health.json'
		$script:json = Join-Path $script:root 'report.json'
		$script:markdown = Join-Path $script:root 'report.md'
		$script:monitor = Join-Path $PSScriptRoot 'test-package-health-monitor.ps1'
		$script:merge = Join-Path $PSScriptRoot 'merge-package-health-scan-results.ps1'
		$script:now = [datetime]'2026-08-16T12:00:00Z'
	}

	It 'preserves prior scan evidence and lets current signed scans replace it' {
		$prior = Join-Path $script:root 'prior.json'
		$evidence = Join-Path $script:root 'evidence'
		$output = Join-Path $script:root 'scan-results.json'
		New-Item -ItemType Directory -Path $evidence | Out-Null
		@(
			[ordered]@{ Name='demo'; State='available'; Reason=''; LastScannedAt='2026-08-10T10:00:00Z'; Digest=('sha256:' + ('a' * 64)) },
			[ordered]@{ Name='never-scanned'; State='available'; Reason=''; LastScannedAt=$null; Digest=$null }
		) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $prior
		[ordered]@{ package='demo'; state='available'; reason=''; scannedAt='2026-08-16T10:00:00Z'; digest=('sha256:' + ('b' * 64)) } |
			ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'demo.health.json')

		& $script:merge -PriorHealthPath $prior -EvidenceRoot $evidence -OutputPath $output
		$result = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
		$result.schemaVersion | Should -Be 1
		@($result.results).Count | Should -Be 1
		$result.results[0].package | Should -Be 'demo'
		$result.results[0].digest | Should -Be ('sha256:' + ('b' * 64))
		([datetime]$result.results[0].scannedAt).ToUniversalTime().ToString('o') | Should -Be '2026-08-16T10:00:00.0000000Z'
	}

	It 'preserves an unsafe family result until an authoritative rescan clears it' {
		$prior = Join-Path $script:root 'prior-unsafe.json'
		$evidence = Join-Path $script:root 'current'
		$conservative = Join-Path $script:root 'conservative.json'
		$authoritative = Join-Path $script:root 'authoritative.json'
		New-Item -ItemType Directory -Path $evidence | Out-Null
		@([ordered]@{ Name='family'; State='scan-blocked'; Reason='CVE'; LastScannedAt='2026-08-10T10:00:00Z'; Digest=$null }) |
			ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $prior
		[ordered]@{ package='family'; state='available'; reason=''; scannedAt='2026-08-16T10:00:00Z'; digest=$null } |
			ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'result.json')

		& $script:merge -PriorHealthPath $prior -EvidenceRoot $evidence -OutputPath $conservative
		& $script:merge -PriorHealthPath $prior -EvidenceRoot $evidence -OutputPath $authoritative -CurrentResultsAuthoritative
		(Get-Content -LiteralPath $conservative -Raw | ConvertFrom-Json).results[0].state | Should -Be 'scan-blocked'
		(Get-Content -LiteralPath $authoritative -Raw | ConvertFrom-Json).results[0].state | Should -Be 'available'
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
