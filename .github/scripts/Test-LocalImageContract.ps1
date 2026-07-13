<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ImageRef,
    [Parameter(Mandatory = $true)][string]$ExpectedImageId,
    [Parameter(Mandatory = $true)][string]$PackageName,
    [Parameter(Mandatory = $true)][string]$PackageVersion,
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$ToolchainSource
)

$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Description mismatch. Expected '$Expected', got '$Actual'."
    }
}

$actualImageId = (& docker image inspect --format '{{.Id}}' $ImageRef | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $actualImageId) {
    throw "Could not inspect candidate image: $ImageRef"
}
Assert-Equal $actualImageId $ExpectedImageId 'Candidate image ID'

$labelsJson = (& docker image inspect --format '{{json .Config.Labels}}' $ImageRef | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $labelsJson -or $labelsJson -eq 'null') {
    throw "Candidate image has no labels: $ImageRef"
}
$labels = $labelsJson | ConvertFrom-Json

Assert-Equal $labels.'io.allsagetech.toolchain.specVersion' '1' 'specVersion label'
Assert-Equal $labels.'io.allsagetech.toolchain.packageName' $PackageName 'packageName label'
Assert-Equal $labels.'io.allsagetech.toolchain.packageVersion' $PackageVersion 'packageVersion label'
Assert-Equal $labels.'io.allsagetech.toolchain.tlcPath' '/.tlc' 'tlcPath label'

$expectedTlcHash = [string]$labels.'io.allsagetech.toolchain.tlcSha256'
if ($expectedTlcHash -notmatch '^[0-9a-f]{64}$') {
    throw "Candidate image has an invalid tlcSha256 label: $expectedTlcHash"
}

$sourceDefinition = Join-Path $PackageRoot '.tlc'
if (-not (Test-Path -LiteralPath $sourceDefinition -PathType Leaf)) {
    throw "Package root does not contain .tlc: $PackageRoot"
}
$sourceHash = (Get-FileHash -LiteralPath $sourceDefinition -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Equal $sourceHash $expectedTlcHash 'Package-root .tlc hash'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('toolchains-contract-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$containerId = $null
try {
    $containerId = (& docker create $ImageRef | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $containerId) {
        throw "Could not create a container from candidate image: $ImageRef"
    }

    $extractedDefinition = Join-Path $tempRoot '.tlc'
    & docker cp "${containerId}:/.tlc" $extractedDefinition
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $extractedDefinition -PathType Leaf)) {
        throw 'Could not extract /.tlc from the candidate image.'
    }

    $extractedHash = (Get-FileHash -LiteralPath $extractedDefinition -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $extractedHash $expectedTlcHash 'Image .tlc hash'

    $toolchainEntryPoint = Join-Path $ToolchainSource 'src/tlc.ps1'
    if (-not (Test-Path -LiteralPath $toolchainEntryPoint -PathType Leaf)) {
        throw "Pinned Toolchain source is missing src/tlc.ps1: $ToolchainSource"
    }
    . $toolchainEntryPoint

    $definition = Get-Content -LiteralPath $extractedDefinition -Raw | ConvertFrom-Json | ConvertTo-HashTable
    Assert-ToolchainDefinition -Definition $definition -Context "candidate image $ImageRef" | Out-Null

    $definitionMaps = @(@{ Name = 'default'; Env = $definition.env })
    foreach ($key in $definition.Keys) {
        if ($key -eq 'env' -or $null -eq $definition[$key]) { continue }
        $definitionMaps += @{ Name = [string]$key; Env = $definition[$key].env }
    }
    foreach ($map in $definitionMaps) {
        $pathValue = $map.Env.Path
        if ($null -eq $pathValue) { $pathValue = $map.Env.PATH }
        $pathEntries = @()
        if ($pathValue -is [string]) {
            $pathEntries = @($pathValue -split ';')
        } elseif ($pathValue -is [Collections.IEnumerable]) {
            $pathEntries = @($pathValue)
        }
        $entryIndex = 0
        foreach ($entry in $pathEntries) {
            $entryIndex++
            $entryText = ([string]$entry).Trim()
            if (-not $entryText -or -not $entryText.StartsWith('${.}')) { continue }
            $relative = $entryText.Substring('${.}'.Length).TrimStart('/', '\')
            if (-not $relative) {
                # `${.}` names the package root itself. Its existence and identity
                # are already proven by the successful /.tlc copy and hash check.
                continue
            }
            if ($relative -match '(^|[\\/])\.\.([\\/]|$)') {
                throw "Configuration '$($map.Name)' contains an unsafe package-relative PATH entry: $entryText"
            }
            $containerPath = '/' + $relative.Replace('\', '/')
            $probePath = Join-Path $tempRoot ("path-{0}-{1}" -f $map.Name, $entryIndex)
            & docker cp "${containerId}:$containerPath" $probePath *> $null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probePath)) {
                throw "Configuration '$($map.Name)' references a PATH entry missing from the exact image: $entryText"
            }
        }
    }
}
finally {
    if ($containerId) {
        & docker rm $containerId *> $null
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Pinned Toolchain contract accepted exact image $ImageRef ($actualImageId)."
