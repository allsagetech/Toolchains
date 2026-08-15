<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PlanPath)
$ErrorActionPreference = 'Stop'
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
if ([int]$plan.schemaVersion -ne 1 -or $null -eq $plan.indexes) { throw 'invalid platform index plan' }
function Get-PlanDigest([string]$Reference) {
	if ($Reference -notmatch '^[a-z0-9._/-]+:[a-z0-9._-]+$') { throw "unsafe planned registry reference: $Reference" }
	$document = (& docker buildx imagetools inspect $Reference --format '{{json .Manifest}}' | Out-String).Trim() | ConvertFrom-Json
	$digest = [string]$document.digest
	if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "could not resolve manifest digest for $Reference" }
	return $digest
}
foreach ($index in @($plan.indexes)) {
	if ([string]$index.target -notmatch '^[a-z0-9._/-]+:[a-z0-9._-]+$' -or @($index.sources).Count -lt 2 -or @($index.leafTags).Count -ne @($index.sources).Count) { throw 'unsafe platform index plan entry' }
	$sources = @()
	for ($sourceIndex = 0; $sourceIndex -lt @($index.sources).Count; $sourceIndex++) {
		$reference = [string]$index.sources[$sourceIndex]
		$repository = ($reference -split ':', 2)[0]
		$digestRef = "$repository@$(Get-PlanDigest $reference)"
		$leafTag = [string]$index.leafTags[$sourceIndex]
		if ($leafTag -notmatch '^[a-z0-9._/-]+:tlc-platform-v1-(?:windows|linux)-amd64--[a-z0-9._-]+--[a-z0-9._-]+$') { throw "unsafe platform leaf tag: $leafTag" }
		& docker buildx imagetools create --prefer-index=false --tag $leafTag $digestRef
		if ($LASTEXITCODE -ne 0) { throw "failed to publish platform leaf $leafTag" }
		$sources += $digestRef
	}
	& docker buildx imagetools create --tag ([string]$index.target) @sources
	if ($LASTEXITCODE -ne 0) { throw "failed to publish multi-platform index $($index.target)" }
	$targetRepository = ([string]$index.target -split ':', 2)[0]
	$indexDigest = Get-PlanDigest ([string]$index.target)
	& cosign sign --yes "$targetRepository@$indexDigest"
	if ($LASTEXITCODE -ne 0) { throw "failed to sign multi-platform index $($index.target)" }
	foreach ($marker in @($index.markers)) {
		if ([string]$marker -notmatch '^[a-z0-9._/-]+:tlc-kind-platform-v1--[a-z0-9._-]+--[a-z0-9._-]+$') { throw "unsafe platform marker: $marker" }
		& docker buildx imagetools create --tag ([string]$marker) "$targetRepository@$indexDigest"
		if ($LASTEXITCODE -ne 0) { throw "failed to publish platform marker $marker" }
	}
	Write-Output "Published $($index.target) for $(@($index.platforms) -join ', ')"
}
