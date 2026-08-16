<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding(DefaultParameterSetName='Expired')]
param(
	[Parameter(Mandatory=$true)][string]$Repository,
	[string]$Username = $env:DOCKERHUB_USERNAME,
	[string]$PersonalAccessToken = $env:DOCKERHUB_TOKEN,
	[Parameter(Mandatory=$true, ParameterSetName='Exact')][string]$Tag,
	[Parameter(ParameterSetName='Expired')][ValidateRange(0, 365)][int]$OlderThanDays = 7,
	[Parameter(ParameterSetName='Expired')][switch]$IncludeOrphanedAttachments,
	[ValidateRange(1, 1440)][int]$SafetyDelayMinutes = 15,
	[switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

$repositoryMatch = [regex]::Match($Repository, '^([a-z0-9][a-z0-9._-]*)/([a-z0-9][a-z0-9._-]*)$')
if (-not $repositoryMatch.Success) {
	throw "Docker Hub repository must be an unqualified namespace/name: $Repository"
}
if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($PersonalAccessToken)) {
	throw 'Docker Hub cleanup requires DOCKERHUB_USERNAME and DOCKERHUB_TOKEN.'
}
if ($PSCmdlet.ParameterSetName -eq 'Exact' -and $Tag -notmatch '^staging-[a-z0-9][a-z0-9._-]*$') {
	throw "Refusing to delete a non-staging Docker tag: $Tag"
}

$namespace = $repositoryMatch.Groups[1].Value
$repositoryName = $repositoryMatch.Groups[2].Value
$namespaceSegment = [Uri]::EscapeDataString($namespace)
$repositorySegment = [Uri]::EscapeDataString($repositoryName)

function Invoke-DockerHubApi {
	param(
		[Parameter(Mandatory=$true)][ValidateSet('Get', 'Post', 'Delete')][string]$Method,
		[Parameter(Mandatory=$true)][string]$Uri,
		[hashtable]$Headers,
		[object]$Body,
		[switch]$AllowNotFound
	)

	for ($attempt = 1; $attempt -le 4; $attempt += 1) {
		try {
			$params = @{
				Method = $Method
				Uri = $Uri
				Headers = $Headers
				TimeoutSec = 60
				ErrorAction = 'Stop'
			}
			if ($null -ne $Body) {
				$params.Body = ($Body | ConvertTo-Json -Compress)
				$params.ContentType = 'application/json'
			}
			return Invoke-RestMethod @params
		} catch {
			$statusCode = $null
			try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { Write-Debug "HTTP status was unavailable: $($_.Exception.Message)" }
			if ($AllowNotFound -and $statusCode -eq 404) { return $null }
			$transient = (-not $statusCode) -or $statusCode -eq 408 -or $statusCode -eq 429 -or $statusCode -ge 500
			if (-not $transient -or $attempt -eq 4) { throw }
			Start-Sleep -Seconds ([math]::Min(15, [math]::Pow(2, $attempt)))
		}
	}
}

$authResponse = Invoke-DockerHubApi `
	-Method Post `
	-Uri 'https://hub.docker.com/v2/auth/token' `
	-Headers @{ 'User-Agent' = $userAgent; Accept = 'application/json' } `
	-Body @{ identifier = $Username; secret = $PersonalAccessToken }
$accessToken = if ($authResponse.access_token) { [string]$authResponse.access_token } else { [string]$authResponse.token }
if ([string]::IsNullOrWhiteSpace($accessToken)) { throw 'Docker Hub authentication did not return an access token.' }
$headers = @{ 'User-Agent' = $userAgent; Accept = 'application/json'; Authorization = "Bearer $accessToken" }

function Remove-DockerHubTag {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[Parameter(Mandatory=$true)][ValidateSet('staging', 'Cosign attachment')][string]$Kind
	)
	$expectedPattern = if ($Kind -eq 'staging') {
		'^staging-[a-z0-9][a-z0-9._-]*$'
	} else {
		'^sha256-[0-9a-f]{64}\.(sig|att)$'
	}
	if ($Name -notmatch $expectedPattern) {
		throw "Refusing to delete a tag that is not an expected $Kind tag: $Name"
	}
	if ($DryRun) {
		Write-Host "Would remove Docker Hub $Kind tag: ${Repository}:$Name"
		return
	}
	$tagSegment = [Uri]::EscapeDataString($Name)
	$uri = "https://hub.docker.com/v2/namespaces/$namespaceSegment/repositories/$repositorySegment/tags/$tagSegment"
	Invoke-DockerHubApi -Method Delete -Uri $uri -Headers $headers -AllowNotFound | Out-Null
	Write-Host "Removed Docker Hub $Kind tag: ${Repository}:$Name"
}

function Get-DockerHubTagInventory {
	$inventory = [Collections.Generic.List[object]]::new()
	$pageSize = 100
	$pageNumber = 1
	while ($true) {
		$uri = "https://hub.docker.com/v2/namespaces/$namespaceSegment/repositories/$repositorySegment/tags?page_size=$pageSize&page=$pageNumber"
		$response = Invoke-DockerHubApi -Method Get -Uri $uri -Headers $headers
		$pageResults = @($response.results)
		foreach ($item in $pageResults) { $inventory.Add($item) }
		# Docker Hub can retain a stale count/next link after bulk tag deletion.
		# A short page is authoritative and prevents a follow-up 404 from making
		# an otherwise complete cleanup inventory fail.
		if ($pageResults.Count -lt $pageSize) { break }
		if (-not $response.next) { break }
		$pageNumber += 1
	}
	return @($inventory)
}

function Get-TagLastUpdatedUtc {
	param([Parameter(Mandatory=$true)][object]$Item)
	if ([string]::IsNullOrWhiteSpace([string]$Item.last_updated)) {
		throw "Docker Hub did not report last_updated for tag '$($Item.name)'."
	}
	return [datetime]::Parse([string]$Item.last_updated).ToUniversalTime()
}

if ($PSCmdlet.ParameterSetName -eq 'Exact') {
	Remove-DockerHubTag -Name $Tag -Kind staging
	return
}

$cutoff = [datetime]::UtcNow.AddDays(-$OlderThanDays).AddMinutes(-$SafetyDelayMinutes)
$inventory = @(Get-DockerHubTagInventory)
$durableDigests = @{}
$freshStagingDigests = @{}
$stagingCandidates = @()

foreach ($item in $inventory) {
	$name = [string]$item.name
	if ($name -match '^sha256-[0-9a-f]{64}\.(sig|att)$') { continue }

	$digest = [string]$item.digest
	if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
		throw "Docker Hub did not report a usable digest for tag '$name'; refusing orphan cleanup."
	}
	if ($name -match '^staging-[a-z0-9][a-z0-9._-]*$') {
		if ((Get-TagLastUpdatedUtc -Item $item) -le $cutoff) {
			$stagingCandidates += $name
		} else {
			$freshStagingDigests[$digest] = $true
		}
		continue
	}

	# Every non-staging, non-attachment tag is durable. Its digest protects the
	# corresponding Cosign signature and attestation tags from deletion.
	$durableDigests[$digest] = $true
}

$attachmentCandidates = @()
if ($IncludeOrphanedAttachments) {
	foreach ($item in $inventory) {
		$name = [string]$item.name
		if ($name -notmatch '^sha256-([0-9a-f]{64})\.(sig|att)$') { continue }
		if ((Get-TagLastUpdatedUtc -Item $item) -gt $cutoff) { continue }

		$subjectDigest = "sha256:$($Matches[1])"
		if ($durableDigests.ContainsKey($subjectDigest)) { continue }
		if ($freshStagingDigests.ContainsKey($subjectDigest)) { continue }
		$attachmentCandidates += $name
	}
}

$stagingCandidates = @($stagingCandidates | Sort-Object -Unique)
$attachmentCandidates = @($attachmentCandidates | Sort-Object -Unique)
$mode = if ($DryRun) { 'Dry-run cleanup plan' } else { 'Cleanup plan' }
Write-Host "$mode for ${Repository}: $($stagingCandidates.Count) staging tag(s) and $($attachmentCandidates.Count) orphaned Cosign attachment tag(s)."

foreach ($name in $stagingCandidates) { Remove-DockerHubTag -Name $name -Kind staging }
foreach ($name in $attachmentCandidates) { Remove-DockerHubTag -Name $name -Kind 'Cosign attachment' }

$verb = if ($DryRun) { 'Would remove' } else { 'Removed' }
Write-Host "$verb $($stagingCandidates.Count) staging tag(s) older than $OlderThanDays day(s) plus the $SafetyDelayMinutes-minute safety delay from $Repository."
if ($IncludeOrphanedAttachments) {
	Write-Host "$verb $($attachmentCandidates.Count) orphaned Cosign attachment tag(s) with no durable image tag reference."
}
