<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
  Name = 'cmake-converter'
}

function global:Install-TlcPackage {
  $BatFile = "\pkg\cmake-converter.bat"
  New-Item -Type Directory -Force (Split-Path $BatFile) | Out-Null

  Set-Content $BatFile @"
@echo off

python -c "import cmake_converter" 2> NUL || python -m pip install --trusted-host pypi.org cmake_converter --quiet --exists-action i
python -m cmake_converter.main %*
"@

  $ErrorActionPreference = 'Stop'

  $scriptsDir = & python -c "import sysconfig; print(sysconfig.get_path('scripts'))"
  if ($scriptsDir) { $env:PATH = "$scriptsDir;$env:PATH" }

  & $BatFile --help | Out-Null

  $ver = (& python -m pip show cmake-converter 2>$null | Select-String -Pattern '^Version:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
  if (-not $ver) {
    $ver = (& python -m pip show cmake_converter 2>$null | Select-String -Pattern '^Version:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
  }
  if (-not $ver) { throw "Could not determine cmake-converter version via pip." }

  $script:Version = [TlcSemanticVersion]::new($ver)
  $TlcPackageConfig.UpToDate = -not $Version.LaterThan($TlcPackageConfig.Latest)
  $TlcPackageConfig.Version  = $Version.ToString()

  if ($TlcPackageConfig.UpToDate) { return }

  $tcRoot = Join-Path $env:LOCALAPPDATA "Toolchain"
  $tcScripts = Get-ChildItem -Path $tcRoot -Recurse -Directory -Filter scripts -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\content\\scripts$' } |
    Select-Object -First 1

  $paths = @(
    (Split-Path $BatFile)
    ($tcScripts?.FullName)
  ) | Where-Object { $_ -and (Test-Path $_) }

  Write-TlcVars @{
    env = @{
      path = ($paths -join ';')
    }
  }
}

function global:Test-TlcPackageInstall {
  $ErrorActionPreference = 'Stop'

  $scriptsDir = & python -c "import sysconfig; print(sysconfig.get_path('scripts'))"
  if ($scriptsDir) { $env:PATH = "$scriptsDir;$env:PATH" }

  $zip = Join-Path $env:TEMP "cmake-converter-test.zip"
  Invoke-WebRequest "https://github.com/MicrosoftDocs/visualstudio-docs/archive/refs/heads/main.zip" `
    -OutFile $zip `
    -Headers @{
      "User-Agent" = "actions-toolchains"
      "Accept"     = "application/octet-stream"
    }

  $extract = Join-Path $env:TEMP "cmake-converter-test"
  if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
  Expand-Archive $zip $extract

  $sln = Get-ChildItem -Recurse $extract -Filter *.sln | Select-Object -First 1
  if (-not $sln) { throw "No .sln found for cmake-converter test." }

  & "\pkg\cmake-converter.bat" -s $sln.FullName
}
