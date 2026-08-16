<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function Test-TlcEnvMap {
	param(
		[Parameter(Mandatory=$true)][object]$EnvMap,
		[string]$Context = 'env'
	)
	if ($EnvMap -isnot [PSCustomObject] -and $EnvMap -isnot [hashtable]) { throw "$Context must be an object/map" }
	$properties = if ($EnvMap -is [hashtable]) { $EnvMap.Keys | ForEach-Object { @{ Name = $_; Value = $EnvMap[$_] } } } else { $EnvMap.PSObject.Properties }
	foreach ($property in $properties) {
		$name = $property.Name
		$value = $property.Value
		if ([string]::IsNullOrWhiteSpace([string]$name)) { throw "$Context contains an empty environment variable name" }
		if ($null -eq $value -or $value -is [string]) { continue }
		if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
			foreach ($item in $value) {
				if ($null -ne $item -and $item -isnot [string]) { throw "$Context.$name must contain only strings" }
			}
			continue
		}
		throw "$Context.$name must be a string or array of strings"
	}
	return $true
}

function Test-TlcToolchainDefinition {
	param(
		[Parameter(Mandatory=$true)][object]$Definition,
		[string]$Context = 'definition'
	)
	if ($null -eq $Definition) { throw "$Context is null" }
	if ($Definition -is [PSCustomObject]) { $Definition = $Definition | ConvertTo-Json -Depth 50 | ConvertFrom-Json }
	$envProperty = $Definition.PSObject.Properties['env']
	if (-not $envProperty) { throw "$Context missing required top-level 'env' object" }
	Test-TlcEnvMap -EnvMap $envProperty.Value -Context "$Context.env" | Out-Null
	foreach ($property in $Definition.PSObject.Properties) {
		if ($property.Name -eq 'env' -or $null -eq $property.Value) { continue }
		$configEnv = $property.Value.PSObject.Properties['env']
		if (-not $configEnv) { throw "$Context.$($property.Name) missing required 'env' object" }
		Test-TlcEnvMap -EnvMap $configEnv.Value -Context "$Context.$($property.Name).env" | Out-Null
	}
	return $true
}

function Get-TlcDefinitionJson {
	$pkgRoot = Get-TlcPkgRoot
	$definitionPath = Join-Path $pkgRoot '.tlc'
	if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
		throw "toolchain definition not found: $definitionPath"
	}
	return (Get-Content -LiteralPath $definitionPath -Raw).Trim()
}

function Assert-TlcDefinitionFile {
	$pkgRoot = Get-TlcPkgRoot
	$definitionPath = Join-Path $pkgRoot '.tlc'
	if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
		throw "toolchain definition not found: $definitionPath"
	}
	$json = (Get-Content -LiteralPath $definitionPath -Raw).Trim()
	$definition = $json | ConvertFrom-Json
	Test-TlcToolchainDefinition -Definition $definition -Context $definitionPath | Out-Null
	return $json
}
