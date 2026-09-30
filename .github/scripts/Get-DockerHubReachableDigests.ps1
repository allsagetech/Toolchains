<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
function Get-DockerHubReachableDigests {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][object]$Item,
		[Parameter(Mandatory=$true)][string]$Repository
	)
	$indexTypes = @('application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json')
	$leafTypes = @('application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json')
	$digests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	$pending = [Collections.Generic.Queue[string]]::new()
	$digest = [string]$Item.digest
	if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Unusable digest for tag '$($Item.name)'." }
	[void]$digests.Add($digest)
	foreach ($image in @($Item.images)) {
		$childDigest = [string]$image.digest
		if ($childDigest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Unusable platform digest for tag '$($Item.name)'." }
		[void]$digests.Add($childDigest)
	}
	# Hub's images summary cannot prove that nested index enumeration is complete.
	# Walk the immutable registry graph before deciding that evidence is orphaned.
	if ([string]$Item.media_type -in $indexTypes) { $pending.Enqueue($digest) }
	elseif ([string]$Item.media_type -notin $leafTypes) { throw "Unknown manifest media type for tag '$($Item.name)'; refusing attachment cleanup." }
	if ($pending.Count -eq 0) { return @($digests) }
	$tokenResponse = Invoke-RestMethod -Method Get -Uri "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$Repository`:pull" -TimeoutSec 60 -ErrorAction Stop
	if ([string]::IsNullOrWhiteSpace([string]$tokenResponse.token)) { throw 'Registry did not return a pull token; refusing attachment cleanup.' }
	$registryHeaders = @{ Authorization = "Bearer $($tokenResponse.token)"; Accept = ($indexTypes + $leafTypes) -join ', ' }
	$visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	while ($pending.Count -gt 0) {
		$reference = $pending.Dequeue()
		if (-not $visited.Add($reference)) { continue }
		$manifest = Invoke-RestMethod -Method Get -Uri "https://registry-1.docker.io/v2/$Repository/manifests/$reference" -Headers $registryHeaders -TimeoutSec 60 -ErrorAction Stop
		if ([string]$manifest.mediaType -notin $indexTypes -or @($manifest.manifests).Count -eq 0) {
			throw "Could not enumerate index $reference; refusing attachment cleanup."
		}
		foreach ($child in @($manifest.manifests)) {
			$childDigest = [string]$child.digest
			if ($childDigest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Unusable child digest in index $reference." }
			[void]$digests.Add($childDigest)
			if ([string]$child.mediaType -in $indexTypes) { $pending.Enqueue($childDigest) }
			elseif ([string]$child.mediaType -notin $leafTypes) { throw "Unknown child media type in index $reference; refusing attachment cleanup." }
		}
	}
	return @($digests)
}
