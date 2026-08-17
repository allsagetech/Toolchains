<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
	[string]$Repository = 'allsagetech/toolchains',
	[Parameter(Mandatory=$true)][string]$Package,
	[Parameter(Mandatory=$true)][string]$Version,
	[Parameter(Mandatory=$true)][string]$AliasTag,
	[Parameter(Mandatory=$true)][string]$ExpectedDigest,
	[string]$CertificateIdentityRegexp = '^https://github\.com/allsagetech/Toolchains/\.github/workflows/build-push\.yml@refs/heads/(main|release/[^/]+)$',
	[string]$CertificateOidcIssuer = 'https://token.actions.githubusercontent.com'
)

$ErrorActionPreference = 'Stop'
if ($Repository -notmatch '^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$') { throw 'Repository must be an explicit lowercase registry namespace/repository.' }
if ($Package -notmatch '^[a-z0-9][a-z0-9._-]*$') { throw 'Package name is invalid.' }
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\+[0-9A-Za-z.-]+)?$') { throw 'Version must be an explicit stable numeric package version.' }
if ($AliasTag -notin @("$Package-latest", "$Package-stable")) { throw "AliasTag must be $Package-latest or $Package-stable." }
$normalizedExpectedDigest = $ExpectedDigest.ToLowerInvariant()
if ($normalizedExpectedDigest -notmatch '^sha256:[0-9a-f]{64}$') { throw 'ExpectedDigest must be a complete SHA-256 registry digest.' }

$versionTag = "$Package-$($Version.Replace('+','_'))"
$source = "$Repository`:$versionTag"
$alias = "$Repository`:$AliasTag"

function Get-RegistryTagDigest {
	param([Parameter(Mandatory=$true)][string]$Reference)
	$json = (& docker buildx imagetools inspect $Reference --format '{{json .Manifest}}' | Out-String).Trim()
	if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { throw "Could not inspect registry reference: $Reference" }
	try { $digest = [string](($json | ConvertFrom-Json).digest) }
	catch { throw "Registry returned invalid manifest metadata for $Reference`: $($_.Exception.Message)" }
	if ($digest -notmatch '^sha256:[0-9a-fA-F]{64}$') { throw "Registry returned an invalid digest for $Reference`: $digest" }
	return $digest.ToLowerInvariant()
}

$targetDigest = Get-RegistryTagDigest -Reference $source
if ($targetDigest -cne $normalizedExpectedDigest) {
	throw "Rollback target digest mismatch for $source (expected $normalizedExpectedDigest, got $targetDigest)."
}
$digestRef = "$Repository@$targetDigest"
$identityArguments = @('--offline','--certificate-identity-regexp',$CertificateIdentityRegexp,'--certificate-oidc-issuer',$CertificateOidcIssuer)
function Invoke-RollbackCosignVerification {
	param(
		[Parameter(Mandatory=$true)][string[]]$Arguments,
		[string[]]$FallbackArguments
	)
	& cosign @Arguments | Out-Null
	if ($LASTEXITCODE -eq 0) { return }
	if ($FallbackArguments) {
		Write-Verbose "Retrying Cosign verification with the standardized bundle format."
		& cosign @FallbackArguments | Out-Null
		if ($LASTEXITCODE -eq 0) { return }
	}
	throw "Cosign verification failed for $digestRef ($($Arguments[0]))."
}
Invoke-RollbackCosignVerification -Arguments (@('verify') + $identityArguments + $digestRef)
Invoke-RollbackCosignVerification `
	-Arguments (@('verify-attestation','--type','spdxjson') + $identityArguments + $digestRef) `
	-FallbackArguments (@('verify-attestation','--new-bundle-format=true','--type','spdxjson') + $identityArguments + $digestRef)
Invoke-RollbackCosignVerification -Arguments (@('verify-attestation','--type','slsaprovenance') + $identityArguments + $digestRef)

$previousDigest = $null
try { $previousDigest = Get-RegistryTagDigest -Reference $alias } catch {
	Write-Verbose "Alias does not currently exist: $alias"
	# A missing optional alias is valid during rehearsal and first promotion. Do
	# not let the caught native inspect failure leak a nonzero process exit.
	$global:LASTEXITCODE = 0
}
$changed = $previousDigest -cne $targetDigest
$applied = $false
if ($changed -and $PSCmdlet.ShouldProcess($alias, "move mutable alias to verified $digestRef")) {
	& docker buildx imagetools create --tag $alias $digestRef
	if ($LASTEXITCODE -ne 0) { throw "Could not move mutable alias $alias." }
	$promotedDigest = Get-RegistryTagDigest -Reference $alias
	if ($promotedDigest -cne $targetDigest) { throw "Rollback alias verification failed (expected $targetDigest, got $promotedDigest)." }
	$applied = $true
}

[pscustomobject]@{
	PSTypeName = 'Toolchains.PackageRollback'
	Package = $Package
	VersionTag = $versionTag
	AliasTag = $AliasTag
	PreviousDigest = $previousDigest
	TargetDigest = $targetDigest
	Changed = $changed
	Applied = $applied
}
