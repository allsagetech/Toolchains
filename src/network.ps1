<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function Get-TlcBrowserUserAgent {
	if ($env:TLC_USER_AGENT) { return [string]$env:TLC_USER_AGENT }
	return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

function Get-TlcRequestHeaders {
	param([hashtable]$Headers)

	$effectiveHeaders = @{}
	if ($Headers) {
		foreach ($key in $Headers.Keys) {
			$effectiveHeaders[[string]$key] = [string]$Headers[$key]
		}
	}
	if (-not $effectiveHeaders.ContainsKey('User-Agent')) {
		$effectiveHeaders['User-Agent'] = Get-TlcBrowserUserAgent
	}
	return $effectiveHeaders
}

function Get-TlcGitHubHeaders {
	$headers = @{
		"User-Agent" = Get-TlcBrowserUserAgent
		"Accept" = "application/vnd.github+json"
		"X-GitHub-Api-Version" = "2022-11-28"
	}
	$token = $env:GH_TOKEN
	if (-not $token) { $token = $env:GITHUB_TOKEN }
	if ($token) {
		$headers["Authorization"] = "Bearer $token"
	}
	return $headers
}

function Invoke-TlcRestMethod {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Uri,
		[hashtable]$Headers,
		[int]$TimeoutSec = 120,
		[int]$MaxRetries = 8,
		[int]$RetryDelaySeconds = 2
	)
	$ErrorActionPreference = 'Stop'
	for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
		try {
			$Params = @{ Uri = $Uri; ErrorAction = 'Stop'; TimeoutSec = $TimeoutSec; Headers = (Get-TlcRequestHeaders -Headers $Headers) }
			return (Invoke-RestMethod @Params)
		} catch {
			$statusCode = $null
			try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
			if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and ($statusCode -notin 408, 429)) { throw }

			if ($attempt -ge $MaxRetries) { throw }
			$delay = [math]::Min(60, $RetryDelaySeconds * [math]::Pow(2, ($attempt - 1)))
			$retryAfter = $null
			try { $retryAfter = $_.Exception.Response.Headers['Retry-After'] } catch { }
			if ($retryAfter) {
				[int]$raSec = 0
				if ([int]::TryParse([string]$retryAfter, [ref]$raSec)) {
					$delay = [math]::Max($delay, $raSec)
				} else {
					try {
						$raDate = [datetime]::Parse([string]$retryAfter)
						$raDelta = [int]([math]::Ceiling(($raDate.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds))
						if ($raDelta -gt 0) { $delay = [math]::Max($delay, $raDelta) }
					} catch { }
				}
			}
			Write-Host "request failed (attempt $attempt/$MaxRetries); retrying in $delay sec: $($_.Exception.Message)"
			Start-Sleep -Seconds $delay
		}
	}
}

function Invoke-TlcWebRequest {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Uri,
		[string]$OutFile,
		[hashtable]$Headers,
		[int]$TimeoutSec = 300,
		[int]$MaxRetries = 8,
		[int]$RetryDelaySeconds = 2,
		[string]$ExpectedSha256,
		[string]$ExpectedHash,
		[ValidateSet('SHA256', 'SHA384', 'SHA512')][string]$ExpectedHashAlgorithm = 'SHA256',
		[switch]$RequireValidAuthenticodeSignature,
		[scriptblock]$SignatureVerifier
	)
	$ErrorActionPreference = 'Stop'
	$hasUseBasicParsing = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('UseBasicParsing')
	if ($OutFile -and -not $ExpectedSha256 -and -not $ExpectedHash -and $global:TlcKnownAssetSha256 -and $global:TlcKnownAssetSha256.ContainsKey($Uri)) {
		$ExpectedSha256 = [string]$global:TlcKnownAssetSha256[$Uri]
	}
	if ($OutFile -and -not $ExpectedSha256 -and -not $ExpectedHash -and ([Uri]$Uri).Host -eq 'github.com') {
		$ExpectedSha256 = Get-TlcGitHubReleaseAssetSha256 -Uri $Uri
	}
	$hasIndependentVerification = [bool]($ExpectedSha256 -or $ExpectedHash -or $RequireValidAuthenticodeSignature -or $SignatureVerifier)
	$requireVerified = $env:TLC_REQUIRE_VERIFIED_DOWNLOADS -in @('1', 'true', 'TRUE', 'yes', 'YES')
	if ($OutFile -and $requireVerified -and -not $hasIndependentVerification) {
		throw "verified downloads are required, but no upstream hash or signature verifier was supplied for $Uri"
	}

	$cacheFile = $null
	if ($OutFile) {
		$destinationParent = Split-Path -Parent $OutFile
		if ($destinationParent -and (-not (Test-Path -LiteralPath $destinationParent -PathType Container))) {
			New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
		}
		$ext = [IO.Path]::GetExtension($OutFile)
		if (-not $ext) { $ext = [IO.Path]::GetExtension(([Uri]$Uri).AbsolutePath) }
		$cacheFile = Get-TlcCachePathForUri -Uri $Uri -Extension ($ext.TrimStart('.'))
		if ($cacheFile -and (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
			$cacheHashPath = "$cacheFile.sha256"
			try {
				if (-not $hasIndependentVerification) { throw 'cache entry has no independent provenance check' }
				Assert-TlcDownloadedFile -Path $cacheFile -Uri $Uri -ExpectedSha256 $ExpectedSha256 -ExpectedHash $ExpectedHash -ExpectedHashAlgorithm $ExpectedHashAlgorithm -RequireValidAuthenticodeSignature:$RequireValidAuthenticodeSignature -SignatureVerifier $SignatureVerifier
				$outputTemp = "$OutFile.partial-$([Guid]::NewGuid().ToString('n'))"
				try {
					Copy-Item -LiteralPath $cacheFile -Destination $outputTemp -Force
					Move-Item -LiteralPath $outputTemp -Destination $OutFile -Force
				} finally {
					Remove-Item -LiteralPath $outputTemp -Force -ErrorAction SilentlyContinue
				}
				return [pscustomobject]@{ StatusCode = 200; FromCache = $true; Path = $OutFile }
			} catch {
				Write-Warning "Discarding invalid cached download for $Uri`: $($_.Exception.Message)"
				Remove-Item -LiteralPath $cacheFile -Force -ErrorAction SilentlyContinue
				Remove-Item -LiteralPath $cacheHashPath -Force -ErrorAction SilentlyContinue
			}
		}
	}
	for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
		$downloadTemp = if ($OutFile) { "$OutFile.partial-$([Guid]::NewGuid().ToString('n'))" } else { $null }
		try {
			$Params = @{ Uri = $Uri; ErrorAction = 'Stop'; TimeoutSec = $TimeoutSec; Headers = (Get-TlcRequestHeaders -Headers $Headers) }
			if ($downloadTemp) { $Params.OutFile = $downloadTemp }
			if ($hasUseBasicParsing) { $Params.UseBasicParsing = $true }
			$resp = (Invoke-WebRequest @Params)
			if ($downloadTemp) {
				Assert-TlcDownloadedFile -Path $downloadTemp -Uri $Uri -ExpectedSha256 $ExpectedSha256 -ExpectedHash $ExpectedHash -ExpectedHashAlgorithm $ExpectedHashAlgorithm -RequireValidAuthenticodeSignature:$RequireValidAuthenticodeSignature -SignatureVerifier $SignatureVerifier
				Move-Item -LiteralPath $downloadTemp -Destination $OutFile -Force
			}
			if ($OutFile -and $cacheFile -and $hasIndependentVerification) {
				$cacheTemp = "$cacheFile.partial-$([Guid]::NewGuid().ToString('n'))"
				$hashTemp = "$cacheFile.sha256.partial-$([Guid]::NewGuid().ToString('n'))"
				try {
					Copy-Item -LiteralPath $OutFile -Destination $cacheTemp -Force
					$downloadSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash.ToLowerInvariant()
					[IO.File]::WriteAllText($hashTemp, $downloadSha256)
					Move-Item -LiteralPath $cacheTemp -Destination $cacheFile -Force
					Move-Item -LiteralPath $hashTemp -Destination "$cacheFile.sha256" -Force
				} finally {
					Remove-Item -LiteralPath $cacheTemp -Force -ErrorAction SilentlyContinue
					Remove-Item -LiteralPath $hashTemp -Force -ErrorAction SilentlyContinue
				}
			}
			return $resp
		} catch {
			if ($downloadTemp) { Remove-Item -LiteralPath $downloadTemp -Force -ErrorAction SilentlyContinue }
			$statusCode = $null
			try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
			if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and ($statusCode -notin 408, 429)) { throw }

			if ($attempt -ge $MaxRetries) { throw }
			$delay = [math]::Min(60, $RetryDelaySeconds * [math]::Pow(2, ($attempt - 1)))
			$retryAfter = $null
			try { $retryAfter = $_.Exception.Response.Headers['Retry-After'] } catch { }
			if ($retryAfter) {
				[int]$raSec = 0
				if ([int]::TryParse([string]$retryAfter, [ref]$raSec)) {
					$delay = [math]::Max($delay, $raSec)
				} else {
					try {
						$raDate = [datetime]::Parse([string]$retryAfter)
						$raDelta = [int]([math]::Ceiling(($raDate.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds))
						if ($raDelta -gt 0) { $delay = [math]::Max($delay, $raDelta) }
					} catch { }
				}
			}
			Write-Host "request failed (attempt $attempt/$MaxRetries); retrying in $delay sec: $($_.Exception.Message)"
			Start-Sleep -Seconds $delay
		}
	}
}

function Get-DockerToken($scope) {
	$service = [uri]::EscapeDataString('registry.docker.io')
	$repositoryScope = [uri]::EscapeDataString("repository:${scope}:pull")
	$resp = Invoke-TlcRestMethod -Uri "https://auth.docker.io/token?service=$service&scope=$repositoryScope"
	$token = if ($resp.token) { [string]$resp.token } else { [string]$resp.access_token }
	if (-not $token) { throw 'Docker registry token response did not contain a token.' }
	return $token
}

function Get-DockerTags([string]$repo) {
	$repositoryPath = (($repo -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
	$token = Get-DockerToken $repo
	$headers = @{
		'Authorization' = "Bearer $token"
		'Accept' = 'application/json'
	}
	$pageSize = 1000
	$last = $null
	$tags = [Collections.Generic.List[string]]::new()
	do {
		$url = "https://registry-1.docker.io/v2/$repositoryPath/tags/list?n=$pageSize"
		if ($last) { $url += "&last=$([uri]::EscapeDataString($last))" }
		$page = Invoke-TlcRestMethod -Uri $url -Headers $headers
		$currentTags = @($page.tags)
		foreach ($tag in $currentTags) {
			if (-not [string]::IsNullOrWhiteSpace([string]$tag)) { $tags.Add([string]$tag) }
		}
		$nextLast = if ($currentTags.Count -gt 0) { [string]$currentTags[-1] } else { $null }
		if ($currentTags.Count -ge $pageSize -and $nextLast -eq $last) {
			throw "Docker registry tag pagination did not advance beyond '$last'."
		}
		$last = $nextLast
	} while ($currentTags.Count -ge $pageSize)

	return @{ tags = @($tags) }
}
