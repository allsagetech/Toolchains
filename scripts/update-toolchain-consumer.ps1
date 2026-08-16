<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
	[Parameter(Mandatory=$true)][string]$Ref,
	[Parameter(Mandatory=$true)][string]$Version,
	[string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
	[switch]$Check
)

$ErrorActionPreference = 'Stop'
if ($Ref -notmatch '^[0-9a-fA-F]{40}$') { throw 'Ref must be a complete 40-character Git commit SHA.' }
$parsedVersion = $null
if (-not [Version]::TryParse($Version.TrimStart('v'), [ref]$parsedVersion)) { throw 'Version must be a stable numeric Toolchain version.' }
$normalizedVersion = $parsedVersion.ToString()
$normalizedRef = $Ref.ToLowerInvariant()
$rootPath = [IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { throw "Toolchains root does not exist: $rootPath" }

function Set-ConsumerFile {
	param(
		[Parameter(Mandatory=$true)][string]$Path,
		[Parameter(Mandatory=$true)][string]$Content
	)
	$current = if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::ReadAllText($Path) } else { '' }
	$normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
	if (-not $normalized.EndsWith("`n")) { $normalized += "`n" }
	if ($current.Replace("`r`n", "`n").Replace("`r", "`n") -ceq $normalized) { return $false }
	if ($Check) { throw "Toolchain consumer promotion is stale: $Path" }
	if ($PSCmdlet.ShouldProcess($Path, "promote Toolchain $normalizedVersion at $normalizedRef")) {
		[IO.File]::WriteAllText($Path, $normalized, [Text.UTF8Encoding]::new($false))
	}
	return $true
}

$manifestPath = Join-Path $rootPath 'toolchain-consumer.json'
$manifest = [ordered]@{
	schemaVersion = 1
	repository = 'allsagetech/toolchain'
	version = $normalizedVersion
	ref = $normalizedRef
}
$manifestText = ($manifest | ConvertTo-Json -Depth 5) + "`n"
$pendingFiles = [ordered]@{ $manifestPath = $manifestText }
$changed = $false
foreach ($item in $pendingFiles.GetEnumerator()) {
	if (Set-ConsumerFile -Path $item.Key -Content $item.Value) { $changed = $true }
}

[pscustomobject]@{
	Version = $normalizedVersion
	Ref = $normalizedRef
	Changed = $changed
	Check = [bool]$Check
}
