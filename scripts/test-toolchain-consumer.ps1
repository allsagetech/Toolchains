<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$Package,
	[Parameter(Mandatory=$true)][string]$Command
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$consumer = Get-Content -LiteralPath (Join-Path $repoRoot 'toolchain-consumer.json') -Raw | ConvertFrom-Json
$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$consumerRoot = Join-Path $tempBase "toolchain-consumer-$([Guid]::NewGuid().ToString('n'))"
$previousPath = $global:ToolchainPath
$previousDisableUpdate = $env:TOOLCHAIN_DISABLE_UPDATE_CHECK

try {
	$env:TOOLCHAIN_DISABLE_UPDATE_CHECK = '1'
	$global:ToolchainPath = $consumerRoot
	Import-Module Toolchain -Force -ErrorAction Stop
	$installedVersion = [string](tlc version)
	if ($installedVersion -ne [string]$consumer.version) {
		throw "Installed Toolchain version $installedVersion does not match promoted version $($consumer.version)."
	}
	Get-Command Get-FileHash -ErrorAction Stop | Out-Null

	tlc pull $Package
	tlc load $Package
	$resolved = Get-Command $Command -ErrorAction Stop
	if (-not (Test-Path -LiteralPath $resolved.Source -PathType Leaf)) {
		throw "Consumer command does not resolve to an installed file: $Command ($($resolved.Source))"
	}
	$contentRoot = [IO.Path]::GetFullPath((Join-Path $consumerRoot 'content')).TrimEnd('\', '/')
	$commandPath = [IO.Path]::GetFullPath([string]$resolved.Source)
	$contentPattern = '^' + [regex]::Escape($contentRoot) + '[\\/]([0-9a-fA-F]{64})(?:[\\/]|$)'
	if ($commandPath -notmatch $contentPattern) {
		throw "Consumer command does not resolve inside Toolchain's digest-addressed content store: $commandPath"
	}
	$digest = "sha256:$($Matches[1].ToLowerInvariant())"

	[pscustomobject]@{
		ToolchainVersion = $installedVersion
		Package = $Package
		Command = $Command
		CommandPath = $resolved.Source
		Digest = $digest
	}
} finally {
	$global:ToolchainPath = $previousPath
	$env:TOOLCHAIN_DISABLE_UPDATE_CHECK = $previousDisableUpdate
	if (Test-Path -LiteralPath $consumerRoot) {
		Remove-Item -LiteralPath $consumerRoot -Recurse -Force -ErrorAction SilentlyContinue
	}
}
