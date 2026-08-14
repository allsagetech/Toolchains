<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
	[switch]$AllUsers,
	[switch]$Quiet,
	[switch]$AcceptLicense,
	[switch]$DownloadOnly,
	[string]$DestinationPath,
	[switch]$KeepInstaller,
	[Alias('h')][switch]$Help
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($Help) {
	@'
Download, verify, and install the Docker Desktop release selected by Toolchains.

Usage:
  docker-desktop-install [-AllUsers] [-Quiet -AcceptLicense]
  docker-desktop-install -DownloadOnly [-DestinationPath <path>]

The default is Docker's per-user, interactive installation. -AllUsers may
require elevation. -Quiet requires -AcceptLicense so license acceptance is
always explicit. The installer is downloaded directly from Docker, checked
against Docker's SHA-256, and verified as Authenticode-signed by Docker Inc.
'@ | Write-Output
	return
}

if ($Quiet -and -not $AcceptLicense) {
	throw '-Quiet requires -AcceptLicense. Review Docker Desktop licensing before accepting it.'
}

$metadataPath = Join-Path $PSScriptRoot 'docker-desktop-release.json'
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
	throw "Docker Desktop release metadata was not found: $metadataPath"
}
$release = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json

if ([string]$release.uri -notmatch '^https://desktop\.docker\.com/win/main/amd64/[0-9]+/Docker(?:%20| )Desktop(?:%20| )Installer\.exe$') {
	throw 'Docker Desktop release metadata contains an unexpected installer URL.'
}
if ([string]$release.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
	throw 'Docker Desktop release metadata contains an invalid SHA-256.'
}

$temporaryRoot = $null
if ($DestinationPath) {
	$installerPath = [IO.Path]::GetFullPath($DestinationPath)
} elseif ($DownloadOnly -or $KeepInstaller) {
	$installerPath = Join-Path (Get-Location).Path ("Docker Desktop Installer-{0}.exe" -f [string]$release.version)
} else {
	$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("toolchain-docker-desktop-{0}" -f [Guid]::NewGuid().ToString('n'))
	$installerPath = Join-Path $temporaryRoot 'Docker Desktop Installer.exe'
}

$installerParent = Split-Path -Parent $installerPath
if (-not (Test-Path -LiteralPath $installerParent -PathType Container)) {
	New-Item -ItemType Directory -Path $installerParent -Force | Out-Null
}

function Assert-DockerDesktopInstaller {
	param([Parameter(Mandatory=$true)][string]$Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw "Docker Desktop installer was not downloaded: $Path"
	}
	[long]$expectedLength = [long]$release.length
	if ((Get-Item -LiteralPath $Path).Length -ne $expectedLength) {
		throw "Docker Desktop installer length does not match Docker's appcast metadata."
	}
	$actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
	if ($actualSha256 -ne ([string]$release.sha256).ToLowerInvariant()) {
		throw "Docker Desktop installer SHA-256 mismatch (expected $($release.sha256), got $actualSha256)."
	}
	$signature = Get-AuthenticodeSignature -LiteralPath $Path
	if ($signature.Status -ne 'Valid') {
		throw "Docker Desktop installer Authenticode signature is not valid (status: $($signature.Status))."
	}
	$subject = [string]$signature.SignerCertificate.Subject
	if ($subject -notmatch '(^|,\s*)CN=Docker Inc(,|$)' -or $subject -notmatch '(^|,\s*)O=Docker Inc(,|$)') {
		throw "Docker Desktop installer is signed by an unexpected publisher: $subject"
	}
}

$partialPath = "$installerPath.partial-$([Guid]::NewGuid().ToString('n'))"
try {
	Write-Host "Downloading Docker Desktop $($release.version) directly from Docker..."
	$request = @{
		Uri = [string]$release.uri
		OutFile = $partialPath
		Headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' }
		TimeoutSec = 1800
		ErrorAction = 'Stop'
	}
	if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('UseBasicParsing')) {
		$request.UseBasicParsing = $true
	}
	Invoke-WebRequest @request | Out-Null
	Assert-DockerDesktopInstaller -Path $partialPath
	Move-Item -LiteralPath $partialPath -Destination $installerPath -Force

	if ($DownloadOnly) {
		Write-Output $installerPath
		return
	}

	$arguments = @('install')
	if (-not $AllUsers) { $arguments += '--user' }
	if ($Quiet) { $arguments += '--quiet' }
	if ($AcceptLicense) { $arguments += '--accept-license' }

	if (-not $AcceptLicense) {
		Write-Host 'Docker Desktop will ask you to review and accept its license in the installer.'
	}
	$process = Start-Process -FilePath $installerPath -ArgumentList $arguments -PassThru -Wait
	if ($process.ExitCode -notin @(0, 3010)) {
		throw "Docker Desktop installer failed with exit code $($process.ExitCode)."
	}
	if ($process.ExitCode -eq 3010) {
		Write-Warning 'Docker Desktop installed successfully, but Windows must be restarted.'
	}
} finally {
	Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
	if (-not $DownloadOnly -and -not $KeepInstaller) {
		Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
	}
	if ($temporaryRoot -and -not $KeepInstaller) {
		Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
	}
}
