<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

Describe 'Offline release rehearsal' {
	It 'builds a deterministic, policy-filtered release matrix without leaking descriptor state' {
		$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
		$outputPath = Join-Path ([IO.Path]::GetTempPath()) "toolchains-release-rehearsal-$([Guid]::NewGuid().ToString('n')).json"
		try {
			& (Join-Path $PSScriptRoot 'test-release-rehearsal.ps1') -OutputPath $outputPath -MaximumCatalogMilliseconds 5000
			$document = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
			$expectedCount = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src/pkgs') -Recurse -File -Filter '*.ps1').Count
			$document.schemaVersion | Should -Be 1
			$document.descriptorCount | Should -Be $expectedCount
			($document.eligibleCount + $document.quarantinedCount) | Should -Be $expectedCount
			$document.publishableCount | Should -BeLessOrEqual $document.eligibleCount
			$document.fingerprint | Should -Match '^[0-9a-f]{64}$'
			@($document.entries | Where-Object { -not $_.publishEligible -and [string]::IsNullOrWhiteSpace($_.quarantineReason) }).Count | Should -Be 0
			Get-Variable TlcPackageConfig -Scope Global -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
			Get-Command Install-TlcPackage -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
		} finally {
			Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
		}
	}
}
