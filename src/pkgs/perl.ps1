<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'perl'
}

function global:Install-TlcPackage {
	$List = (Invoke-TlcWebRequest -Uri 'https://raw.githubusercontent.com/StrawberryPerl/strawberryperl.com/gh-pages/releases.json').Content | ConvertFrom-Json
	foreach ($Item in $List) {
		if ($Item.archname -eq 'MSWin32-x64-multi-thread') {
			$Version = $Item.version
			$AssetName = "strawberry-perl-$Version.zip"
			if ([string]$Item.edition.portable.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "Strawberry Perl release metadata is missing SHA-256 for $AssetName" }
			$Params = @{
				AssetName = $AssetName
				AssetURL = $Item.edition.portable.url
				ExpectedSha256 = [string]$Item.edition.portable.sha256
			}
			$v = [TlcSemanticVersion]::new($Version, '^([0-9]+)\.([0-9]+)\.([0-9]+)(\.[0-9]+)')
			$TlcPackageConfig.UpToDate = -not $v.LaterThan($TlcPackageConfig.Latest)
			$TlcPackageConfig.Version = $v.ToString()
			if ($TlcPackageConfig.UpToDate) {
				return
			}
			Install-BuildTool @Params
			$MakeDirectory = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'gmake.exe' | Select-Object -First 1).DirectoryName
			if (-not (Test-Path $MakeDirectory\make.exe)) {
				New-Item -ItemType HardLink $MakeDirectory\make.exe -Target $MakeDirectory\gmake.exe
			}
			Write-TlcVars @{
				env = @{
					path = (@(
						(Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'perl.exe' | Select-Object -First 1).DirectoryName,
						$MakeDirectory
					) -join ';')
				}
			}
			return
		}
	}
	Write-Error "Failed to find an x64 build for StrawberryPerl"
}

function global:Test-TlcPackageInstall {
	Get-Content (Get-TlcPkgPath '.tlc')
}
