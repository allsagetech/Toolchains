<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

param(
  [string]$Repo = $(if ($env:TOOLCHAIN_REPO) { $env:TOOLCHAIN_REPO } else { 'allsagetech/toolchain' }),
  [string]$Ref  = $(if ($env:TOOLCHAIN_REF) { $env:TOOLCHAIN_REF } else { 'pipeline' }),
  [string]$Token = $(if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $null })
)

$ErrorActionPreference = 'Stop'

function Get-TempRoot {
  if ($env:RUNNER_TEMP) {
    New-Item -ItemType Directory -Path $env:RUNNER_TEMP -Force | Out-Null
    return $env:RUNNER_TEMP
  }

  $tmp = [System.IO.Path]::GetTempPath()
  if ([string]::IsNullOrWhiteSpace($tmp)) {
    if ($env:TEMP) { return $env:TEMP }
    throw "Could not determine a temporary directory (RUNNER_TEMP/TEMP are unset)."
  }
  return $tmp
}

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
    [string]$Description = 'operation',
    [int]$MaxRetries = 5,
    [int]$InitialDelaySeconds = 2
  )

  for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
      return (& $ScriptBlock)
    } catch {
      if ($attempt -ge $MaxRetries) { throw }
      $delay = [math]::Min(60, $InitialDelaySeconds * [math]::Pow(2, ($attempt - 1)))
      Write-Host "$Description failed (attempt $attempt/$MaxRetries); retrying in $delay sec: $($_.Exception.Message)"
      Start-Sleep -Seconds $delay
    }
  }
}

$zipUrl = "https://api.github.com/repos/$Repo/zipball/$Ref"
$tempRoot = Get-TempRoot
$nonce = [Guid]::NewGuid().ToString('n')
$zip    = Join-Path $tempRoot "toolchain-$nonce.zip"
$dest   = Join-Path $tempRoot "toolchain-src-$nonce"

$headers = @{
  "User-Agent" = "actions-toolchains"
  "Accept"     = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
}
if ($Token) {
  $headers["Authorization"] = "Bearer $Token"
}

Invoke-WithRetry -Description 'Toolchain source download' -ScriptBlock {
  Invoke-WebRequest $zipUrl -OutFile $zip -Headers $headers
}

if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Path $dest -Force | Out-Null

try {
  Expand-Archive -Path $zip -DestinationPath $dest -Force

  $root = Get-ChildItem -Path $dest -Directory | Select-Object -First 1
  if (-not $root) { throw "Unzip produced no root folder." }

  Push-Location $root.FullName
  try {
    if (-not (Test-Path ".\\build.ps1")) { throw "No build.ps1 found in Toolchain repo zip." }

    $psExe = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    if ($psExe) {
      & $psExe.Source -NoProfile -ExecutionPolicy Bypass -File ".\\build.ps1"
    } else {
      & powershell -NoProfile -ExecutionPolicy Bypass -File ".\\build.ps1"
    }

    $buildDir = Join-Path $PWD "build"
    if (-not (Test-Path $buildDir)) { throw "Expected build directory was not created: $buildDir" }

    $psd1 = Get-ChildItem -Path $buildDir -Recurse -Filter "Toolchain.psd1" | Select-Object -First 1
    if (-not $psd1) { throw "Could not find Toolchain.psd1 under build/" }

    $manifest = Import-PowerShellDataFile $psd1.FullName
    $ver = [string]$manifest.ModuleVersion
    if (-not $ver) { throw "Toolchain.psd1 missing ModuleVersion" }

    $moduleSrc = Split-Path -Parent $psd1.FullName

    $pwshModsRoot = Join-Path $HOME "Documents\\PowerShell\\Modules"
    $winModsRoot  = Join-Path $HOME "Documents\\WindowsPowerShell\\Modules"

    $pwshMods = Join-Path $pwshModsRoot "Toolchain\\$ver"
    $winMods  = Join-Path $winModsRoot  "Toolchain\\$ver"

    New-Item -ItemType Directory -Path $pwshMods -Force | Out-Null
    New-Item -ItemType Directory -Path $winMods  -Force | Out-Null

    Copy-Item -Path (Join-Path $moduleSrc "*") -Destination $pwshMods -Recurse -Force
    Copy-Item -Path (Join-Path $moduleSrc "*") -Destination $winMods  -Recurse -Force

    $sep = [System.IO.Path]::PathSeparator
    $env:PSModulePath = "$pwshModsRoot${sep}$winModsRoot${sep}$env:PSModulePath"
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
      "PSModulePath=$($env:PSModulePath)" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    } else {
      Write-Host "GITHUB_ENV is not set; PSModulePath updated for this process only."
    }

    Import-Module Toolchain -Force
    Get-Command toolchain -ErrorAction Stop | Out-Null
  } finally {
    Pop-Location
  }
} finally {
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
}
