<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'windows-terminal'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'microsoft'
		Repo = 'terminal'
		AssetPattern = 'Microsoft\.WindowsTerminal(Preview)?.+\.msixbundle'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+).*$'
	}
	$Asset = Get-GitHubRelease @Params
	$TlcPackageConfig.UpToDate = -not $Asset.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Asset.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$bundle = "$env:Temp\$($Asset.Name)"
	Invoke-TlcWebRequest -Uri $Asset.URL -OutFile $bundle
	Expand-Archive $bundle "$env:temp\bundle"
	Expand-Archive "$env:temp\bundle\CascadiaPackage_$($Asset.Identifier.Substring(1))_x64.msix" "\pkg"
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'wt.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		Get-Command wt
	}
}