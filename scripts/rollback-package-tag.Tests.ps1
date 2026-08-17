<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

Describe 'Signed package alias rollback' {
	BeforeEach {
		$global:RollbackTarget = 'sha256:' + ('a' * 64)
		$global:RollbackPrevious = 'sha256:' + ('b' * 64)
		$global:RollbackAliasDigest = $global:RollbackPrevious
		$global:RollbackAliasExists = $true
		$global:RollbackCosignCalls = 0
		$global:RollbackCreateCalls = 0
		function global:docker {
			if ($args[1] -eq 'imagetools' -and $args[2] -eq 'inspect') {
				$reference = [string]$args[3]
				if ($reference -notlike '*:demo-1.2.3' -and -not $global:RollbackAliasExists) {
					$global:LASTEXITCODE = 1
					return
				}
				$digest = if ($reference -like '*:demo-1.2.3') { $global:RollbackTarget } else { $global:RollbackAliasDigest }
				$global:LASTEXITCODE = 0
				return (@{ digest=$digest } | ConvertTo-Json -Compress)
			}
			if ($args[1] -eq 'imagetools' -and $args[2] -eq 'create') {
				$global:RollbackCreateCalls++
				$global:RollbackAliasDigest = $global:RollbackTarget
				$global:LASTEXITCODE = 0
				return
			}
			$global:LASTEXITCODE = 1
		}
		function global:cosign { $global:RollbackCosignCalls++; $global:LASTEXITCODE = 0 }
		$script:rollback = Join-Path $PSScriptRoot 'rollback-package-tag.ps1'
	}

	AfterEach {
		Remove-Item Function:\global:docker -Force -ErrorAction SilentlyContinue
		Remove-Item Function:\global:cosign -Force -ErrorAction SilentlyContinue
		Remove-Variable RollbackTarget,RollbackPrevious,RollbackAliasDigest,RollbackAliasExists,RollbackCosignCalls,RollbackCreateCalls -Scope Global -Force -ErrorAction SilentlyContinue
	}

	It 'verifies signature and attestations before moving only the mutable alias' {
		$result = & $script:rollback -Repository owner/repo -Package demo -Version 1.2.3 -AliasTag demo-stable -ExpectedDigest $global:RollbackTarget -Confirm:$false
		$result.Changed | Should -BeTrue
		$result.Applied | Should -BeTrue
		$result.PreviousDigest | Should -Be $global:RollbackPrevious
		$result.TargetDigest | Should -Be $global:RollbackTarget
		$global:RollbackCosignCalls | Should -Be 3
		$global:RollbackCreateCalls | Should -Be 1
	}

	It 'supports WhatIf and rejects unsafe targets before mutation' {
		$result = & $script:rollback -Repository owner/repo -Package demo -Version 1.2.3 -AliasTag demo-latest -ExpectedDigest $global:RollbackTarget -WhatIf
		$result.Applied | Should -BeFalse
		$global:RollbackCreateCalls | Should -Be 0
		{ & $script:rollback -Repository owner/repo -Package demo -Version 1.2.3 -AliasTag demo-1.2.2 -ExpectedDigest $global:RollbackTarget -Confirm:$false } | Should -Throw '*AliasTag must*'
		{ & $script:rollback -Repository owner/repo -Package demo -Version 1.2.3 -AliasTag demo-stable -ExpectedDigest ('sha256:' + ('c' * 64)) -Confirm:$false } | Should -Throw '*digest mismatch*'
		$global:RollbackCreateCalls | Should -Be 0
	}

	It 'accepts a signed SBOM reference attestation for an external SPDX artifact' {
		function global:cosign {
			$global:RollbackCosignCalls++
			$isLegacySbomAttempt = $args -contains 'spdxjson'
			$global:LASTEXITCODE = if ($isLegacySbomAttempt) { 1 } else { 0 }
		}
		$result = & $script:rollback -Repository owner/repo -Package demo -Version 1.2.3 -AliasTag demo-stable -ExpectedDigest $global:RollbackTarget -Confirm:$false
		$result.Applied | Should -BeTrue
		$global:RollbackCosignCalls | Should -Be 4
		$global:RollbackCreateCalls | Should -Be 1
	}

	It 'treats a missing optional alias as a clean WhatIf result' {
		$global:RollbackAliasExists = $false
		$result = & $script:rollback -Repository owner/repo -Package demo -Version 1.2.3 -AliasTag demo-stable -ExpectedDigest $global:RollbackTarget -WhatIf
		$result.PreviousDigest | Should -BeNullOrEmpty
		$result.Changed | Should -BeTrue
		$result.Applied | Should -BeFalse
		$global:LASTEXITCODE | Should -Be 0
		$global:RollbackCreateCalls | Should -Be 0
	}

	It 'fails closed when signed evidence cannot be verified' {
		function global:cosign { $global:RollbackCosignCalls++; $global:LASTEXITCODE = 1 }
		{ & $script:rollback -Repository owner/repo -Package demo -Version 1.2.3 -AliasTag demo-stable -ExpectedDigest $global:RollbackTarget -Confirm:$false } | Should -Throw '*Cosign verification failed*'
		$global:RollbackCreateCalls | Should -Be 0
	}
}
