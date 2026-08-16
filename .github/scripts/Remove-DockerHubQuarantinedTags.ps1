<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$Repository,
	[string]$Username = $env:DOCKERHUB_USERNAME,
	[string]$PersonalAccessToken = $env:DOCKERHUB_TOKEN,
	[string]$RepositoryRoot = (Join-Path $PSScriptRoot '../..'),
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
	throw 'Docker Hub quarantine cleanup requires DOCKERHUB_USERNAME and DOCKERHUB_TOKEN.'
}

$repositoryRootPath = [IO.Path]::GetFullPath($RepositoryRoot)
$mainScript = Join-Path $repositoryRootPath 'src/main.ps1'
$packageRoot = Join-Path $repositoryRootPath 'src/pkgs'
if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) { throw "Toolchains main script not found: $mainScript" }
if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) { throw "Toolchains package directory not found: $packageRoot" }

. $mainScript
$descriptorStates = @()
foreach ($script in @(Get-ChildItem -LiteralPath $packageRoot -Filter '*.ps1' -Recurse -File | Sort-Object FullName)) {
	$config = (Read-TlcPackageDescriptor -Path $script.FullName).Config
	$state = Get-TlcPackagePublicationState -Config $config
	$descriptorStates += [pscustomobject]@{
		Name = [string]$config.Name
		Matcher = [string]$config.Matcher
		PublishEligible = [bool]$state.PublishEligible
		Reason = [string]$state.QuarantineReason
		Script = $script.FullName
	}
}

$rules = [Collections.Generic.List[object]]::new()
foreach ($group in @($descriptorStates | Group-Object Name | Sort-Object Name)) {
	$quarantined = @($group.Group | Where-Object { -not $_.PublishEligible })
	if ($quarantined.Count -eq 0) { continue }

	if ($quarantined.Count -eq $group.Count) {
		$rules.Add([pscustomobject]@{
			Name = $group.Name
			Pattern = '^' + [regex]::Escape($group.Name) + '-(?:v?[0-9])'
			Reason = (@($quarantined.Reason | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
		})
		continue
	}

	foreach ($descriptor in $quarantined) {
		if ([string]::IsNullOrWhiteSpace($descriptor.Matcher)) {
			throw "Partially quarantined package '$($descriptor.Name)' requires a tag Matcher to avoid deleting supported versions: $($descriptor.Script)"
		}
		$requiredPrefix = '^' + [regex]::Escape($descriptor.Name) + '-'
		if (-not $descriptor.Matcher.StartsWith($requiredPrefix, [StringComparison]::Ordinal)) {
			throw "Quarantine Matcher '$($descriptor.Matcher)' is not anchored to package '$($descriptor.Name)': $($descriptor.Script)"
		}
		try { [void][regex]::new($descriptor.Matcher) } catch { throw "Invalid quarantine Matcher '$($descriptor.Matcher)': $($descriptor.Script)" }
		$rules.Add([pscustomobject]@{
			Name = $descriptor.Name
			Pattern = $descriptor.Matcher
			Reason = $descriptor.Reason
		})
	}
}

$namespaceSegment = [Uri]::EscapeDataString($repositoryMatch.Groups[1].Value)
$repositorySegment = [Uri]::EscapeDataString($repositoryMatch.Groups[2].Value)

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

$inventory = [Collections.Generic.List[object]]::new()
$pageSize = 100
$pageNumber = 1
while ($true) {
	$uri = "https://hub.docker.com/v2/namespaces/$namespaceSegment/repositories/$repositorySegment/tags?page_size=$pageSize&page=$pageNumber"
	$response = Invoke-DockerHubApi -Method Get -Uri $uri -Headers $headers
	$pageResults = @($response.results)
	foreach ($item in $pageResults) { $inventory.Add($item) }
	if ($pageResults.Count -lt $pageSize) { break }
	if (-not $response.next) { break }
	$pageNumber += 1
}

$tagCandidates = [Collections.Generic.List[object]]::new()
$candidateNames = @{}
$candidateDigests = @{}
foreach ($item in @($inventory)) {
	$name = [string]$item.name
	if ($name -match '^staging-' -or $name -match '^sha256-[0-9a-f]{64}\.(sig|att)$' -or $name -match '^tlc-kind-model-v1-') { continue }
	foreach ($rule in $rules) {
		if ($name -notmatch $rule.Pattern) { continue }
		$digest = [string]$item.digest
		if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Docker Hub did not report a usable digest for quarantined tag '$name'." }
		$tagCandidates.Add([pscustomobject]@{ Name = $name; Digest = $digest; Rule = $rule })
		$candidateNames[$name] = $true
		$candidateDigests[$digest] = $true
		break
	}
}

$remainingDurableDigests = @{}
foreach ($item in @($inventory)) {
	$name = [string]$item.name
	if ($candidateNames.ContainsKey($name)) { continue }
	if ($name -match '^staging-' -or $name -match '^sha256-[0-9a-f]{64}\.(sig|att)$') { continue }
	$digest = [string]$item.digest
	if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Docker Hub did not report a usable digest for durable tag '$name'." }
	$remainingDurableDigests[$digest] = $true
}

$attachmentCandidates = [Collections.Generic.List[string]]::new()
foreach ($item in @($inventory)) {
	$name = [string]$item.name
	if ($name -notmatch '^sha256-([0-9a-f]{64})\.(sig|att)$') { continue }
	$subjectDigest = "sha256:$($Matches[1])"
	if (-not $candidateDigests.ContainsKey($subjectDigest)) { continue }
	if ($remainingDurableDigests.ContainsKey($subjectDigest)) { continue }
	$attachmentCandidates.Add($name)
}

$tagCandidates = @($tagCandidates | Sort-Object Name -Unique)
$attachmentCandidates = @($attachmentCandidates | Sort-Object -Unique)
$mode = if ($DryRun) { 'Dry-run quarantine cleanup plan' } else { 'Quarantine cleanup plan' }
Write-Host "$mode for ${Repository}: $($tagCandidates.Count) package tag(s) and $($attachmentCandidates.Count) orphaned Cosign attachment tag(s)."
foreach ($candidate in $tagCandidates) {
	Write-Host "  $($candidate.Name): $($candidate.Rule.Reason)"
}

function Remove-DockerHubTag {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[Parameter(Mandatory=$true)][ValidateSet('quarantined package', 'Cosign attachment')][string]$Kind
	)
	if ($Kind -eq 'quarantined package' -and -not $candidateNames.ContainsKey($Name)) {
		throw "Refusing to delete a tag that was not selected from a quarantined descriptor: $Name"
	}
	if ($Kind -eq 'Cosign attachment' -and $Name -notmatch '^sha256-[0-9a-f]{64}\.(sig|att)$') {
		throw "Refusing to delete a tag that is not a Cosign attachment: $Name"
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

foreach ($candidate in $tagCandidates) { Remove-DockerHubTag -Name $candidate.Name -Kind 'quarantined package' }
foreach ($name in $attachmentCandidates) { Remove-DockerHubTag -Name $name -Kind 'Cosign attachment' }

$verb = if ($DryRun) { 'Would remove' } else { 'Removed' }
Write-Host "$verb $($tagCandidates.Count) quarantined package tag(s) and $($attachmentCandidates.Count) orphaned Cosign attachment tag(s) from $Repository."
