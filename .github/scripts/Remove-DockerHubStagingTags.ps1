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
	[Parameter(ParameterSetName='Expired')][ValidateRange(0, 365)][int]$OlderThanDays = 7
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

if ($Repository -notmatch '^([a-z0-9][a-z0-9._-]*)/([a-z0-9][a-z0-9._-]*)$') {
	throw "Docker Hub repository must be an unqualified namespace/name: $Repository"
}
if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($PersonalAccessToken)) {
	throw 'Docker Hub cleanup requires DOCKERHUB_USERNAME and DOCKERHUB_TOKEN.'
}
if ($PSCmdlet.ParameterSetName -eq 'Exact' -and $Tag -notmatch '^staging-[a-z0-9][a-z0-9._-]*$') {
	throw "Refusing to delete a non-staging Docker tag: $Tag"
}

$namespace = $Matches[1]
$repositoryName = $Matches[2]
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
			try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
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

function Remove-StagingTag {
	param([Parameter(Mandatory=$true)][string]$Name)
	if ($Name -notmatch '^staging-[a-z0-9][a-z0-9._-]*$') {
		throw "Refusing to delete a non-staging Docker tag: $Name"
	}
	$tagSegment = [Uri]::EscapeDataString($Name)
	$uri = "https://hub.docker.com/v2/namespaces/$namespaceSegment/repositories/$repositorySegment/tags/$tagSegment"
	Invoke-DockerHubApi -Method Delete -Uri $uri -Headers $headers -AllowNotFound | Out-Null
	Write-Host "Removed Docker Hub staging tag: ${Repository}:$Name"
}

if ($PSCmdlet.ParameterSetName -eq 'Exact') {
	Remove-StagingTag -Name $Tag
	return
}

$cutoff = [datetime]::UtcNow.AddDays(-$OlderThanDays)
$uri = "https://hub.docker.com/v2/namespaces/$namespaceSegment/repositories/$repositorySegment/tags?page_size=100&page=1"
$candidates = @()
while ($uri) {
	$response = Invoke-DockerHubApi -Method Get -Uri $uri -Headers $headers
	foreach ($item in @($response.results)) {
		$name = [string]$item.name
		if ($name -notmatch '^staging-[a-z0-9][a-z0-9._-]*$') { continue }
		$lastUpdated = [datetime]::Parse([string]$item.last_updated).ToUniversalTime()
		if ($lastUpdated -gt $cutoff) { continue }
		$candidates += $name
	}
	$uri = if ($response.next) { [string]$response.next } else { $null }
}
foreach ($name in ($candidates | Sort-Object -Unique)) { Remove-StagingTag -Name $name }
Write-Host "Removed $(@($candidates | Sort-Object -Unique).Count) staging tag(s) older than $OlderThanDays day(s) from $Repository."
