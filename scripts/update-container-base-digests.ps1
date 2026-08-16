<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

[CmdletBinding()]
param(
	[switch]$Check,
	[string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
	[hashtable]$DigestOverride = @{}
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

function Get-RegistryBearerToken {
	param(
		[Parameter(Mandatory=$true)][Net.Http.HttpClient]$Client,
		[Parameter(Mandatory=$true)][string]$Challenge
	)
	$parameters = @{}
	foreach ($match in [regex]::Matches($Challenge, '(\w+)="([^"]*)"')) { $parameters[$match.Groups[1].Value] = $match.Groups[2].Value }
	$realm = [string]$parameters.realm
	if (-not [Uri]::IsWellFormedUriString($realm, [UriKind]::Absolute)) { throw "Registry Bearer challenge has an invalid realm: $Challenge" }
	$query = @()
	foreach ($name in @('service', 'scope')) {
		if ($parameters[$name]) { $query += "$name=$([Uri]::EscapeDataString([string]$parameters[$name]))" }
	}
	$tokenUri = if ($query.Count -gt 0) { "$realm`?$($query -join '&')" } else { $realm }
	$response = $Client.GetAsync($tokenUri).GetAwaiter().GetResult()
	try {
		if (-not $response.IsSuccessStatusCode) { throw "Registry token endpoint returned HTTP $([int]$response.StatusCode)." }
		$payload = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
		$token = if ($payload.token) { [string]$payload.token } else { [string]$payload.access_token }
		if (-not $token) { throw 'Registry token response did not contain a token.' }
		return $token
	} finally { $response.Dispose() }
}

function Get-RegistryManifestDigest {
	param(
		[Parameter(Mandatory=$true)][string]$Registry,
		[Parameter(Mandatory=$true)][string]$Repository,
		[Parameter(Mandatory=$true)][string]$Tag
	)
	$uri = "https://$Registry/v2/$Repository/manifests/$([Uri]::EscapeDataString($Tag))"
	$client = [Net.Http.HttpClient]::new()
	$client.Timeout = [TimeSpan]::FromSeconds(30)
	try {
		$authorization = $null
		for ($attempt = 1; $attempt -le 2; $attempt++) {
			$request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Head, $uri)
			foreach ($mediaType in @(
				'application/vnd.oci.image.index.v1+json',
				'application/vnd.docker.distribution.manifest.list.v2+json',
				'application/vnd.oci.image.manifest.v1+json',
				'application/vnd.docker.distribution.manifest.v2+json'
			)) { $request.Headers.Accept.ParseAdd($mediaType) }
			if ($authorization) { $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $authorization) }
			$response = $client.SendAsync($request).GetAwaiter().GetResult()
			$request.Dispose()
			if ([int]$response.StatusCode -eq 401 -and -not $authorization) {
				$challenge = @($response.Headers.WwwAuthenticate | Where-Object Scheme -eq 'Bearer' | Select-Object -First 1)
				$response.Dispose()
				if ($challenge.Count -ne 1) { throw "Registry did not provide one Bearer challenge for $Repository`:$Tag." }
				$authorization = Get-RegistryBearerToken -Client $client -Challenge $challenge[0].ToString()
				continue
			}
			try {
				if (-not $response.IsSuccessStatusCode) { throw "Registry manifest request returned HTTP $([int]$response.StatusCode) for $Repository`:$Tag." }
				$values = [string[]]@($response.Headers.GetValues('Docker-Content-Digest'))
				if ($values.Count -ne 1 -or $values[0] -notmatch '^sha256:[0-9a-f]{64}$') { throw "Registry returned an invalid manifest digest for $Repository`:$Tag." }
				return $values[0]
			} finally { $response.Dispose() }
		}
		throw "Registry authentication did not complete for $Repository`:$Tag."
	} finally { $client.Dispose() }
}

$bases = @(
	@{
		Reference = 'mcr.microsoft.com/windows/nanoserver:ltsc2022'
		Registry = 'mcr.microsoft.com'
		Repository = 'windows/nanoserver'
		Tag = 'ltsc2022'
		Files = @('Dockerfile')
	}
)

$stale = [Collections.Generic.List[string]]::new()
$updated = [Collections.Generic.List[string]]::new()
foreach ($base in $bases) {
	$digest = if ($DigestOverride.ContainsKey($base.Reference)) {
		[string]$DigestOverride[$base.Reference]
	} else {
		Get-RegistryManifestDigest -Registry $base.Registry -Repository $base.Repository -Tag $base.Tag
	}
	if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Invalid resolved digest for $($base.Reference): $digest" }
	$pattern = [regex]::Escape([string]$base.Reference) + '@sha256:[0-9a-f]{64}'
	$replacement = "$($base.Reference)@$digest"
	foreach ($relativePath in $base.Files) {
		$path = Join-Path $RepositoryRoot $relativePath
		if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Digest-managed file does not exist: $relativePath" }
		$content = [IO.File]::ReadAllText($path)
		$referenceMatches = [regex]::Matches($content, $pattern)
		if ($referenceMatches.Count -eq 0) { throw "Digest-managed reference $($base.Reference) is missing from $relativePath" }
		if (@($referenceMatches | Where-Object Value -ne $replacement).Count -eq 0) { continue }
		$stale.Add("$relativePath`: $($base.Reference) -> $digest")
		if (-not $Check) {
			[IO.File]::WriteAllText($path, [regex]::Replace($content, $pattern, $replacement), [Text.UTF8Encoding]::new($false))
			$updated.Add($relativePath)
		}
	}
}

if ($Check -and $stale.Count -gt 0) { throw "Container base digests are stale:`n$($stale -join [Environment]::NewLine)" }
if ($updated.Count -gt 0) { Write-Output "Updated container base digests in $(@($updated | Sort-Object -Unique).Count) file(s)." }
else { Write-Output 'Container base digests are current.' }
