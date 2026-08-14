<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
	[string]$InstallDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'toolchains-cosign-v2.6.0')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$version = 'v2.6.0'
$isWindowsHost = $env:RUNNER_OS -eq 'Windows' -or $env:OS -eq 'Windows_NT'
$isLinuxHost = $env:RUNNER_OS -eq 'Linux' -or (-not $isWindowsHost -and [Environment]::OSVersion.Platform -eq [PlatformID]::Unix)
if ($env:RUNNER_ARCH -and $env:RUNNER_ARCH -ne 'X64') {
	throw "Cosign bootstrap supports only X64 runners; received '$env:RUNNER_ARCH'."
}

if ($isWindowsHost) {
	$assetName = 'cosign-windows-amd64.exe'
	$executableName = 'cosign.exe'
	$expectedSha256 = '7beb4dd1e19a72c328bbf7c0d7342d744edbf5cbb082f227b2b76e04a21c16ef'
} elseif ($isLinuxHost) {
	$assetName = 'cosign-linux-amd64'
	$executableName = 'cosign'
	$expectedSha256 = 'ea5c65f99425d6cfbb5c4b5de5dac035f14d09131c1a0ea7c7fc32eab39364f9'
} else {
	throw "Cosign bootstrap does not support this operating system: $([Environment]::OSVersion.Platform)"
}

$uri = "https://github.com/sigstore/cosign/releases/download/$version/$assetName"
$headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0' }
$tempPath = Join-Path ([IO.Path]::GetTempPath()) "toolchains-$assetName-$([Guid]::NewGuid().ToString('n'))"

try {
	$downloaded = $false
	for ($attempt = 1; $attempt -le 3 -and -not $downloaded; $attempt++) {
		try {
			Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -UseBasicParsing -OutFile $tempPath
			$downloaded = $true
		} catch {
			if ($attempt -eq 3) { throw }
			Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
		}
	}

	$actualSha256 = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash.ToLowerInvariant()
	if ($actualSha256 -cne $expectedSha256) {
		throw "Cosign SHA-256 mismatch for $assetName. Expected $expectedSha256, received $actualSha256."
	}

	New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
	$destination = Join-Path $InstallDirectory $executableName
	Move-Item -LiteralPath $tempPath -Destination $destination -Force
	if ($isLinuxHost) {
		& chmod '+x' $destination
		if ($LASTEXITCODE -ne 0) { throw "Could not make Cosign executable: $destination" }
	}

	if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_PATH)) {
		$InstallDirectory | Out-File -LiteralPath $env:GITHUB_PATH -Append -Encoding utf8
	}
	& $destination version
	if ($LASTEXITCODE -ne 0) { throw "Cosign verification command failed with exit code $LASTEXITCODE." }
} finally {
	if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
}
