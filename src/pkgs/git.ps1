<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'git'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'git-for-windows'
		Repo = 'git'
		AssetPattern = 'PortableGit-.+?64-bit\.7z\.exe'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)\.windows(\.[0-9]+)$'
	}
	$Asset = Get-GitHubRelease @Params
	$TlcPackageConfig.UpToDate = -not $Asset.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Asset.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$git = "$env:Temp\$($Asset.Name)"
	Invoke-TlcWebRequest -Uri $Asset.URL -OutFile $git
	Invoke-TlcWebRequest -Uri 'https://www.7-zip.org/a/7za920.zip' -OutFile "$env:temp\7z.zip"
	Expand-Archive "$env:temp\7z.zip" "$env:temp\7z"
	& "$env:temp\7z\7za.exe" x -o'\pkg' $git | Out-Null
	& (Get-ChildItem -Path '\pkg' -Recurse -Include 'git.exe' | Select-Object -First 1) config --system --unset credential.helper
	Write-TlcVars @{
		env = @{
			path = (@(
				(Get-ChildItem -Path '\pkg' -Recurse -Include 'gitk.exe' | Select-Object -First 1).DirectoryName,
				(Get-ChildItem -Path '\pkg' -Recurse -Include 'sed.exe' | Select-Object -First 1).DirectoryName,
				(Get-ChildItem -Path '\pkg' -Recurse -Include 'curl.exe' | Select-Object -First 1).DirectoryName
			) -join ';')
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		git --version
		curl.exe --version
		sed --version
	}
}