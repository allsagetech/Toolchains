<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name    = 'notepadpp'
    Matcher = '^npp\.8\.'
}

function global:Install-TlcPackage {
    $Params = @{
        Owner      = 'notepad-plus-plus'
        Repo       = 'notepad-plus-plus'
        TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
    }

    $Latest = Get-GitHubTag @Params

    $TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
    $TlcPackageConfig.Version  = $Latest.Version.ToString()

    if ($TlcPackageConfig.UpToDate) {
        return
    }

    $Tag          = $Latest.name
    $VersionPlain = $Tag.TrimStart('v')

    $AssetName = "npp.$VersionPlain.portable.x64.zip"

    $Params = @{
        AssetName = $AssetName
        AssetURL  = "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/$Tag/$AssetName"
    }

    Install-BuildTool @Params

    Write-TlcVars @{
        env = @{
            path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'notepad++.exe' |
                    Select-Object -First 1).DirectoryName
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        notepad++ -?
    }
}
