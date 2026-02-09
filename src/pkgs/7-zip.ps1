<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = '7-zip'
	Version = '25.1.0'
}

function global:Install-TlcPackage {
    if ($TlcPackageConfig.Latest -and ($TlcPackageConfig.Latest -eq $TlcPackageConfig.Version)) {
        $TlcPackageConfig.UpToDate = $true
        return
    }

    $TlcPackageConfig.UpToDate = $false

    $installer = Join-Path $env:TEMP '7zInstall.exe'
    Invoke-TlcWebRequest -Uri 'https://www.7-zip.org/a/7z2501-x64.exe' -OutFile $installer

    $pkgRoot = (Resolve-Path '\pkg').Path
    $proc = Start-Process -FilePath $installer -ArgumentList @('/S', "/D=$pkgRoot") -PassThru -Wait
    if ($proc.ExitCode -ne 0) { throw "7-zip installer failed with exit code $($proc.ExitCode)" }

    Write-TlcVars @{
        env = @{
            path = (Get-ChildItem -Path '\pkg' -Recurse -Include '7z.exe' | Select-Object -First 1).DirectoryName
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        7z
    }
}
