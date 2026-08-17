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
  $BatFile = (Get-TlcPkgPath 'cmake-converter.bat')
  New-Item -Type Directory -Force (Split-Path $BatFile) | Out-Null

  Set-Content $BatFile @"
@echo off

python -c "import cmake_converter" 2> NUL || python -m pip install cmake_converter --quiet --exists-action i --disable-pip-version-check
python -m cmake_converter.main %*
"@

  $python = Get-TlcApplicationPath -Name 'python'
  $oldPipVersionCheck = $env:PIP_DISABLE_PIP_VERSION_CHECK
  try {
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    try {
      Invoke-TlcNativeCommand -FilePath $python -ArgumentList @('-c', 'import cmake_converter') `
        -FailureMessage 'cmake-converter import probe failed'
    } catch {
      Invoke-TlcNativeCommand -FilePath $python `
        -ArgumentList @('-m', 'pip', 'install', 'cmake_converter', '--quiet', '--exists-action', 'i', '--disable-pip-version-check') `
        -FailureMessage 'cmake-converter installation failed'
    }

    $scriptsDir = (Invoke-TlcNativeCommand -FilePath $python `
      -ArgumentList @('-c', "import sysconfig; print(sysconfig.get_path('scripts'))") `
      -FailureMessage 'Python scripts-directory discovery failed' -PassThru).Trim()
    if ($scriptsDir) { $env:PATH = "$scriptsDir;$env:PATH" }

    Invoke-TlcNativeCommand -FilePath $python -ArgumentList @('-m', 'cmake_converter.main', '--help') `
      -FailureMessage 'cmake-converter help probe failed'

    $pipShow = Invoke-TlcNativeCommand -FilePath $python `
      -ArgumentList @('-m', 'pip', 'show', 'cmake-converter', '--disable-pip-version-check') `
      -FailureMessage 'cmake-converter version discovery failed' -PassThru
    $ver = ($pipShow | Select-String -Pattern '^Version:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
  } finally {
    $env:PIP_DISABLE_PIP_VERSION_CHECK = $oldPipVersionCheck
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
  Invoke-TlcWebRequest -Uri "https://github.com/MicrosoftDocs/visualstudio-docs/archive/refs/heads/main.zip" `
    -OutFile $zip `
    -Headers @{
      "Accept"     = "application/octet-stream"
    }

  $extract = Join-Path $env:TEMP "cmake-converter-test"
  if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
  Expand-Archive $zip $extract

  $sln = Get-ChildItem -Recurse $extract -Filter *.sln | Select-Object -First 1
  if (-not $sln) { throw "No .sln found for cmake-converter test." }

  & (Get-TlcPkgPath 'cmake-converter.bat') -s $sln.FullName
}
