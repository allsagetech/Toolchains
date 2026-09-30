<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
BeforeAll {
	$repoRoot = Split-Path $PSScriptRoot -Parent
	$parentDigest = 'sha256:' + ('a' * 64)
	$childDigest = 'sha256:' + ('b' * 64)
}
Describe 'Platform attachment cleanup' {
	BeforeEach {
		$global:TlcCleanupTestDeleted = @()
		$global:TlcCleanupTestManifests = @{}
		$global:TlcCleanupTestInventory = @(
			[pscustomobject]@{ name = 'kubectl-1.36.4_1'; digest = $parentDigest; media_type = 'application/vnd.docker.distribution.manifest.v2+json'; images = @([pscustomobject]@{ digest = $childDigest }); last_updated = '2020-01-01T00:00:00Z' }
			[pscustomobject]@{ name = 'sha256-' + ('b' * 64) + '.sig'; last_updated = '2020-01-01T00:00:00Z' }
			[pscustomobject]@{ name = 'sha256-' + ('b' * 64) + '.att'; last_updated = '2020-01-01T00:00:00Z' }
			[pscustomobject]@{ name = 'sha256-' + ('c' * 64) + '.sig'; last_updated = '2020-01-01T00:00:00Z' }
		)
		Mock Invoke-RestMethod {
			if ($Uri -like 'https://auth.docker.io/*') { return @{ token = 'pull-token' } }
			if ($Uri -like 'https://registry-1.docker.io/*') { return $global:TlcCleanupTestManifests[([string]$Uri).Split('/')[-1]] }
			if ($Method -eq 'Post') { return @{ access_token = 'test-token' } }
			if ($Method -eq 'Delete') { $global:TlcCleanupTestDeleted += $Uri; return }
			return @{ results = $global:TlcCleanupTestInventory; next = $null }
		}
	}
	It 'retains child signatures and attestations while deleting a true orphan' {
		& "$repoRoot/.github/scripts/Remove-DockerHubStagingTags.ps1" -Repository example/tools -Username test -PersonalAccessToken test -IncludeOrphanedAttachments
		$global:TlcCleanupTestDeleted.Count | Should -Be 1
		$global:TlcCleanupTestDeleted[0] | Should -Match ('sha256-' + ('c' * 64) + '\.sig$')
	}
	It 'fails closed when a durable platform image lacks a digest' {
		$global:TlcCleanupTestInventory[0].images[0].digest = ''
		{ & "$repoRoot/.github/scripts/Remove-DockerHubStagingTags.ps1" -Repository example/tools -Username test -PersonalAccessToken test -IncludeOrphanedAttachments } | Should -Throw '*Unusable platform digest*'
		$global:TlcCleanupTestDeleted.Count | Should -Be 0
	}
	It 'retains evidence reachable through a nested index absent from the Hub image summary' {
		$nestedDigest = 'sha256:' + ('d' * 64)
		$global:TlcCleanupTestInventory[0].media_type = 'application/vnd.oci.image.index.v1+json'
		$global:TlcCleanupTestInventory[0].images = @()
		$global:TlcCleanupTestManifests[$parentDigest] = @{ mediaType = 'application/vnd.oci.image.index.v1+json'; manifests = @(@{ digest = $nestedDigest; mediaType = 'application/vnd.oci.image.index.v1+json' }) }
		$global:TlcCleanupTestManifests[$nestedDigest] = @{ mediaType = 'application/vnd.oci.image.index.v1+json'; manifests = @(@{ digest = $childDigest; mediaType = 'application/vnd.oci.image.manifest.v1+json' }) }
		& "$repoRoot/.github/scripts/Remove-DockerHubStagingTags.ps1" -Repository example/tools -Username test -PersonalAccessToken test -IncludeOrphanedAttachments
		$global:TlcCleanupTestDeleted.Count | Should -Be 1
		$global:TlcCleanupTestDeleted[0] | Should -Match ('sha256-' + ('c' * 64) + '\.sig$')
	}
	It 'fails before deleting anything when index enumeration is incomplete' {
		$global:TlcCleanupTestInventory[0].media_type = 'application/vnd.oci.image.index.v1+json'
		{ & "$repoRoot/.github/scripts/Remove-DockerHubStagingTags.ps1" -Repository example/tools -Username test -PersonalAccessToken test -IncludeOrphanedAttachments } | Should -Throw '*Could not enumerate index*'
		$global:TlcCleanupTestDeleted.Count | Should -Be 0
	}
	It 'fails closed on unknown nested manifest types' {
		$global:TlcCleanupTestInventory[0].media_type = 'application/vnd.oci.image.index.v1+json'
		$global:TlcCleanupTestManifests[$parentDigest] = @{ mediaType = 'application/vnd.oci.image.index.v1+json'; manifests = @(@{ digest = $childDigest; mediaType = 'unknown' }) }
		{ & "$repoRoot/.github/scripts/Remove-DockerHubStagingTags.ps1" -Repository example/tools -Username test -PersonalAccessToken test -IncludeOrphanedAttachments } | Should -Throw '*Unknown child media type*'
		$global:TlcCleanupTestDeleted.Count | Should -Be 0
	}
	It 'retains reachable evidence for a fresh staging index' {
		$global:TlcCleanupTestInventory[0].name = 'staging-kubectl-test'
		$global:TlcCleanupTestInventory[0].media_type = 'application/vnd.oci.image.index.v1+json'
		$global:TlcCleanupTestManifests[$parentDigest] = @{ mediaType = 'application/vnd.oci.image.index.v1+json'; manifests = @(@{ digest = $childDigest; mediaType = 'application/vnd.oci.image.manifest.v1+json' }) }
		$global:TlcCleanupTestInventory[0].last_updated = [datetime]::UtcNow.ToString('o')
		& "$repoRoot/.github/scripts/Remove-DockerHubStagingTags.ps1" -Repository example/tools -Username test -PersonalAccessToken test -IncludeOrphanedAttachments
		$global:TlcCleanupTestDeleted.Count | Should -Be 1
		$global:TlcCleanupTestDeleted[0] | Should -Match ('sha256-' + ('c' * 64) + '\.sig$')
	}
	It 'protects child evidence shared by a retained tag during quarantine cleanup' {
		# The quarantined tag references the same child as a retained platform index.
		$global:TlcCleanupTestInventory += [pscustomobject]@{ name = 'miktex-1.0'; digest = $childDigest }
		$fixture = Join-Path $TestDrive 'repo'
		New-Item "$fixture/src/pkgs" -ItemType Directory -Force | Out-Null
		Set-Content "$fixture/src/pkgs/quarantined.ps1" '# fixture'
		Set-Content "$fixture/src/main.ps1" @'
function Read-TlcPackageDescriptor { param($Path) return @{ Config = @{ Name = 'miktex'; Matcher = '' } } }
function Get-TlcPackagePublicationState { param($Config) return @{ PublishEligible = $false; QuarantineReason = 'fixture' } }
'@
		& "$repoRoot/.github/scripts/Remove-DockerHubQuarantinedTags.ps1" -Repository example/tools -Username test -PersonalAccessToken test -RepositoryRoot $fixture
		$global:TlcCleanupTestDeleted.Count | Should -Be 1
		$global:TlcCleanupTestDeleted[0] | Should -Match 'miktex-1.0$'
	}
}

AfterAll {
	Remove-Variable TlcCleanupTestInventory, TlcCleanupTestDeleted, TlcCleanupTestManifests -Scope Global -ErrorAction SilentlyContinue
}
