<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function Assert-TlcDownloadedFile {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][string]$Path,
		[Parameter(Mandatory=$true)][string]$Uri,
		[string]$ExpectedSha256,
		[string]$ExpectedHash,
		[ValidateSet('SHA256', 'SHA384', 'SHA512')][string]$ExpectedHashAlgorithm = 'SHA256',
		[switch]$RequireValidAuthenticodeSignature,
		[scriptblock]$SignatureVerifier
	)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw "download did not create a file for $Uri"
	}
	if ((Get-Item -LiteralPath $Path).Length -le 0) {
		throw "downloaded file is empty for $Uri"
	}

	if ($ExpectedSha256) {
		$normalized = $ExpectedSha256.Trim().ToLowerInvariant()
		if ($normalized -notmatch '^[0-9a-f]{64}$') { throw "invalid expected SHA-256 for $Uri" }
		$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
		if ($actual -ne $normalized) { throw "SHA-256 mismatch for $Uri (expected $normalized, got $actual)" }
	}
	if ($ExpectedHash) {
		$normalized = ($ExpectedHash -replace '\s', '').ToLowerInvariant()
		if ($normalized -notmatch '^[0-9a-f]+$') { throw "invalid expected $ExpectedHashAlgorithm hash for $Uri" }
		$actual = (Get-FileHash -Algorithm $ExpectedHashAlgorithm -LiteralPath $Path).Hash.ToLowerInvariant()
		if ($actual -ne $normalized) { throw "$ExpectedHashAlgorithm mismatch for $Uri (expected $normalized, got $actual)" }
	}

	if ($RequireValidAuthenticodeSignature) {
		$signatureCommand = Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue
		if (-not $signatureCommand) { throw "Authenticode verification is unavailable for $Uri" }
		$signature = Get-AuthenticodeSignature -LiteralPath $Path
		if ($signature.Status -ne 'Valid') { throw "Authenticode signature is not valid for $Uri (status: $($signature.Status))" }
	}
	if ($SignatureVerifier) {
		$verified = & $SignatureVerifier $Path $Uri
		if (-not $verified) { throw "signature verification failed for $Uri" }
	}
}

function Test-TlcAuthenticodeZip {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][string]$Path,
		[Parameter(Mandatory=$true)][string]$Uri,
		[string]$RequiredExecutable
	)
	$signatureCommand = Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue
	if (-not $signatureCommand) { throw "Authenticode verification is unavailable for $Uri" }
	$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("toolchains-signature-$([Guid]::NewGuid().ToString('n'))")
	try {
		Expand-Archive -LiteralPath $Path -DestinationPath $tempRoot -Force
		$executables = @(Get-ChildItem -LiteralPath $tempRoot -Filter '*.exe' -Recurse -File)
		if ($executables.Count -eq 0) { throw "signed archive contains no executables: $Uri" }
		if ($RequiredExecutable -and -not ($executables | Where-Object { $_.Name -eq $RequiredExecutable } | Select-Object -First 1)) {
			throw "signed archive is missing required executable $RequiredExecutable`: $Uri"
		}
		foreach ($executable in $executables) {
			$signature = Get-AuthenticodeSignature -LiteralPath $executable.FullName
			if ($signature.Status -ne 'Valid') { throw "Authenticode signature is not valid for $($executable.Name) in $Uri (status: $($signature.Status))" }
		}
		return $true
	} finally {
		Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}
}

function Get-TlcRemoteSha256 {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][string]$ChecksumUri,
		[string]$AssetName,
		[hashtable]$Headers
	)
	return Get-TlcRemoteHash -ChecksumUri $ChecksumUri -AssetName $AssetName -Headers $Headers -Algorithm SHA256
}

function Get-TlcRemoteHash {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][string]$ChecksumUri,
		[string]$AssetName,
		[hashtable]$Headers,
		[ValidateSet('SHA256', 'SHA384', 'SHA512')][string]$Algorithm = 'SHA256'
	)
	$response = Invoke-TlcWebRequest -Uri $ChecksumUri -Headers $Headers
	$content = if ($response.Content -is [byte[]]) {
		[Text.Encoding]::UTF8.GetString([byte[]]$response.Content)
	} else {
		[string]$response.Content
	}
	if ([string]::IsNullOrWhiteSpace($content)) { throw "checksum document is empty: $ChecksumUri" }
	$hexLength = switch ($Algorithm) { 'SHA256' { 64 } 'SHA384' { 96 } 'SHA512' { 128 } }

	if ($AssetName) {
		$escapedName = [regex]::Escape($AssetName)
		$match = [regex]::Match($content, "(?im)^([0-9a-f]{$hexLength})\s+\*?(?:.*/)?$escapedName\s*$")
		if (-not $match.Success) { throw "$Algorithm for $AssetName was not found in $ChecksumUri" }
		return $match.Groups[1].Value.ToLowerInvariant()
	}

	$match = [regex]::Match($content, "(?i)\b([0-9a-f]{$hexLength})\b")
	if (-not $match.Success) { throw "$Algorithm was not found in $ChecksumUri" }
	return $match.Groups[1].Value.ToLowerInvariant()
}

function Get-TlcGitHubReleaseAssetSha256 {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][string]$Uri
	)
	$parsed = [Uri]$Uri
	if ($parsed.Host -ne 'github.com') { return $null }
	$match = [regex]::Match($parsed.AbsolutePath, '^/([^/]+)/([^/]+)/releases/download/([^/]+)/(.+)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
	if (-not $match.Success) { return $null }

	$owner = [Uri]::UnescapeDataString($match.Groups[1].Value)
	$repo = [Uri]::UnescapeDataString($match.Groups[2].Value)
	$tag = [Uri]::UnescapeDataString($match.Groups[3].Value)
	$assetName = [Uri]::UnescapeDataString($match.Groups[4].Value)
	$escapedTag = [Uri]::EscapeDataString($tag)
	$release = Invoke-TlcRestMethod -Uri "https://api.github.com/repos/$owner/$repo/releases/tags/$escapedTag" -Headers (Get-TlcGitHubHeaders)
	$asset = @($release.assets) | Where-Object { [string]$_.name -eq $assetName } | Select-Object -First 1
	$digest = if ($asset) { [string]$asset.digest } else { $null }
	if ($digest -match '^sha256:([0-9a-fA-F]{64})$') {
		return $Matches[1].ToLowerInvariant()
	}

	$checksumNames = @("$assetName.sha256.txt", "$assetName.sha256")
	$checksumAsset = @($release.assets) |
		Where-Object { [string]$_.name -in $checksumNames } |
		Select-Object -First 1
	$checksumUri = if ($checksumAsset) { [string]$checksumAsset.browser_download_url } else { $null }
	if ($checksumUri) {
		# A companion asset is unambiguous because its name includes the complete
		# payload filename. Parse the sole SHA-256 value so both common publisher
		# formats (hash-only and "hash filename") are supported.
		return Get-TlcRemoteSha256 -ChecksumUri $checksumUri -Headers (Get-TlcGitHubHeaders)
	}
	return $null
}
