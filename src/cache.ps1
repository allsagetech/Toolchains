<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function Get-TlcPkgRoot {
	$root = $env:TLC_PKG_ROOT
	if (-not $root) { $root = '\pkg' }

	try {
		return [System.IO.Path]::GetFullPath($root)
	} catch {
		return $root
	}
}

function Get-TlcPkgPath {
	param([string]$ChildPath)
	$root = Get-TlcPkgRoot
	if ([string]::IsNullOrWhiteSpace($ChildPath)) { return $root }
	return (Join-Path $root $ChildPath.TrimStart('\', '/'))
}

function ConvertTo-TlcCanonicalPathList {
	[CmdletBinding()]
	param(
		[AllowNull()][AllowEmptyString()][string]$Value,
		[string]$ContainedRoot
	)

	if ($null -eq $Value) { return $null }
	$rootPath = $null
	$rootPrefix = $null
	if (-not [string]::IsNullOrWhiteSpace($ContainedRoot)) {
		$rootPath = [IO.Path]::GetFullPath($ContainedRoot).TrimEnd('\', '/')
		$rootPrefix = $rootPath + [IO.Path]::DirectorySeparatorChar
	}

	$normalized = foreach ($entry in ($Value -split ';')) {
		if ([string]::IsNullOrWhiteSpace($entry)) {
			$entry
			continue
		}
		$candidate = $entry.Trim()
		if (-not [IO.Path]::IsPathRooted($candidate)) {
			if ($candidate -match '(^|[\\/])\.\.([\\/]|$)') { throw "Relative path-list entry contains parent traversal: $candidate" }
			$candidate
			continue
		}
		try { $fullPath = [IO.Path]::GetFullPath($candidate) }
		catch { throw "Could not canonicalize path-list entry '$candidate': $($_.Exception.Message)" }

		if ($rootPath) {
			$candidateForComparison = $candidate.Replace([IO.Path]::AltDirectorySeparatorChar, [IO.Path]::DirectorySeparatorChar)
			$startedInsideRoot = $candidateForComparison.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or $candidateForComparison.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
			$staysInsideRoot = $fullPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
			if ($startedInsideRoot -and -not $staysInsideRoot) { throw "Path-list entry escapes its required root '$rootPath': $candidate" }
		}
		$fullPath
	}
	return ($normalized -join ';')
}

function Get-TlcStagingPath {
	param([string]$ChildPath)
	$root = $env:TLC_STAGING_ROOT
	if ([string]::IsNullOrWhiteSpace($root)) { $root = Join-Path ([IO.Path]::GetTempPath()) 'toolchains-staging' }
	if ([string]::IsNullOrWhiteSpace($ChildPath)) { return $root }
	return (Join-Path $root $ChildPath.TrimStart('\', '/'))
}

function Get-Tlc7ZipExecutable {
	if ($script:Tlc7ZipExecutable -and (Test-Path -LiteralPath $script:Tlc7ZipExecutable -PathType Leaf)) { return $script:Tlc7ZipExecutable }
	$sevenZipRoot = Join-Path ([IO.Path]::GetTempPath()) ("tlc-7zip-$PID")
	$installer = Join-Path ([IO.Path]::GetTempPath()) '7z2501-x64.exe'
	Invoke-TlcWebRequest -Uri 'https://github.com/ip7z/7zip/releases/download/25.01/7z2501-x64.exe' -OutFile $installer
	if (Test-Path -LiteralPath $sevenZipRoot) { Remove-Item -LiteralPath $sevenZipRoot -Recurse -Force }
	New-Item -ItemType Directory -Path $sevenZipRoot -Force | Out-Null
	$proc = Start-Process -FilePath $installer -ArgumentList @('/S', "/D=$sevenZipRoot") -PassThru -Wait
	if ($proc.ExitCode -ne 0) { throw "7-zip bootstrap installer failed with exit code $($proc.ExitCode)" }
	$exe = Get-ChildItem -Path $sevenZipRoot -Recurse -Filter '7z.exe' -File | Select-Object -First 1
	if (-not $exe) { throw 'Failed to bootstrap 7z.exe from the integrity-verified installer.' }
	$script:Tlc7ZipExecutable = $exe.FullName
	return $script:Tlc7ZipExecutable
}

function Get-TlcCacheRoot {
	$root = $env:TLC_CACHE_ROOT
	if (-not $root) { $root = Join-Path (Get-TlcPkgRoot) 'cache' }
	if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
	return $root
}

function Get-TlcCachePathForUri {
	param(
		[Parameter(Mandatory=$true)][string]$Uri,
		[string]$Extension
	)
	$bytes = [Text.Encoding]::UTF8.GetBytes($Uri)
	$sha = [Security.Cryptography.SHA256]::Create()
	try { $hashBytes = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
	$hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
	if (-not $Extension) { $Extension = '' }
	if ($Extension -and (-not $Extension.StartsWith('.'))) { $Extension = '.' + $Extension }
	return (Join-Path (Get-TlcCacheRoot) ($hex + $Extension))
}

function Get-TlcPkgUri {
	$root = Get-TlcPkgRoot
	$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
	if ($isWindowsHost) {
		$path = $root.Replace('\', '/')
		if ($path -match '^[A-Za-z]:/') { return "file:///$path" }
		if (-not $path.StartsWith('/')) { $path = "/$path" }
		return "file:///$path"
	}
	$path = $root.Replace('\', '/')
	if (-not $path.StartsWith('/')) { $path = "/$path" }
	return "file://$path"
}
