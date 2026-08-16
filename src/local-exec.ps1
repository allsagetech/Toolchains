<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function Expand-TlcEnvValue {
	param(
		[AllowNull()][object]$Value,
		[Parameter(Mandatory=$true)][string]$PkgRoot
	)
	if ($null -eq $Value) { return $null }
	$expandOne = {
		param([string]$Text)
		$out = $Text.Replace('${.}', $PkgRoot)
		$out = [regex]::Replace($out, '(?i)(?<![A-Za-z]:)\\pkg', { param($match) $PkgRoot })
		return $out
	}
	if ($Value -is [string]) { return (& $expandOne $Value) }
	if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
		$out = @()
		foreach ($item in $Value) {
			if ($null -eq $item) { continue }
			if ($item -isnot [string]) { throw 'env value array must contain only strings' }
			$out += (& $expandOne $item)
		}
		return $out
	}
	throw 'env value must be a string or array of strings'
}

function Invoke-TlcLocalExec {
	param(
		[Parameter(Mandatory=$true)][string]$Spec,
		[Parameter(Mandatory=$true)][ScriptBlock]$Block
	)
	$specText = $Spec.Trim()
	$configName = $null
	if ($specText -match '^(.*?)<\s*(.+)$') { $configName = $Matches[2].Trim() }
	$pkgRoot = Get-TlcPkgRoot
	$definitionPath = Join-Path $pkgRoot '.tlc'
	if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) { throw "toolchain definition not found: $definitionPath" }
	$definition = (Get-Content -LiteralPath $definitionPath -Raw).Trim() | ConvertFrom-Json -AsHashtable
	if (-not $definition.ContainsKey('env')) { throw "toolchain definition missing required top-level 'env' object: $definitionPath" }
	$envMap = $definition['env']
	if ($configName) {
		if (-not $definition.ContainsKey($configName)) { throw "toolchain config not found in ${definitionPath}: $configName" }
		$config = $definition[$configName]
		if ($config -isnot [hashtable] -or -not $config.ContainsKey('env')) { throw "toolchain config '$configName' missing required 'env' object: $definitionPath" }
		$envMap = $config['env']
	}

	$originals = @{}
	try {
		foreach ($key in $envMap.Keys) {
			$declaredName = [string]$key
			$name = if ($declaredName -ieq 'path') {
				if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { 'Path' } else { 'PATH' }
			} else { $declaredName }
			$original = Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
			$originals[$name] = if ($original) { @{ Exists = $true; Value = $original.Value } } else { @{ Exists = $false } }
			$value = Expand-TlcEnvValue -Value $envMap[$key] -PkgRoot $pkgRoot
			if ($declaredName -ieq 'path') {
				$separator = [System.IO.Path]::PathSeparator
				$oldPath = (Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue).Value
				if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { $value = ($value -join $separator) }
				if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
				$valueText = ([string]$value).Trim($separator)
				$merged = if ([string]::IsNullOrWhiteSpace($oldPath)) { $valueText } else { "$valueText$separator$oldPath" }
				Set-Item -LiteralPath "Env:$name" -Value $merged
			} else {
				if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { $value = ($value -join [System.IO.Path]::PathSeparator) }
				if ($null -eq $value) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
				else { Set-Item -LiteralPath "Env:$name" -Value $value }
			}
		}
		& $Block
	} finally {
		foreach ($name in $originals.Keys) {
			$info = $originals[$name]
			if ($info.Exists) {
				if ($null -eq $info.Value) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
				else { Set-Item -LiteralPath "Env:$name" -Value $info.Value }
			} else { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
		}
	}
}

function Toolchain {
	[CmdletBinding()]
	param(
		[Parameter(Position=0, Mandatory=$true)][string]$Verb,
		[Parameter(Position=1, Mandatory=$true)][string]$Spec,
		[Parameter(Position=2, Mandatory=$true)][ScriptBlock]$Block
	)
	if ($Verb -ne 'exec') { throw 'Toolchains wrapper only supports: Toolchain exec <spec> { ... }' }
	Invoke-TlcLocalExec -Spec $Spec -Block $Block
}
