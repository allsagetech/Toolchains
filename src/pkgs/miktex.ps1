<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'MiKTeX'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'MiKTeX'
		Repo = 'miktex'
		TagPattern = '^([0-9]+)\.([0-9]+)\.?([0-9]+)?$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$downloadPage = [Net.WebUtility]::HtmlDecode([string](Invoke-TlcWebRequest -Uri 'https://miktex.org/download').Content)
	$fileMatch = [regex]::Match($downloadPage, '(?i)\b(miktexsetup-[0-9.+-]+-x64\.zip)\b')
	if (-not $fileMatch.Success) { throw 'MiKTeX download metadata is missing the setup utility filename.' }
	$AssetName = $fileMatch.Groups[1].Value
	$metadataTail = $downloadPage.Substring($fileMatch.Index, [Math]::Min(1600, $downloadPage.Length - $fileMatch.Index))
	$hashMatch = [regex]::Match($metadataTail, '(?is)SHA-256:</div>.*?([0-9a-f]{64})</div>')
	if (-not $hashMatch.Success) { throw "MiKTeX download metadata is missing SHA-256 for $AssetName" }
	$PackageSet = 'basic'
	$ToolDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Get-TlcPkgRoot))
	$Asset = "$env:Temp/$AssetName"
	$AssetURL = "https://miktex.org/download/ctan/systems/win32/miktex/setup/windows-x64/$AssetName"
	Invoke-TlcWebRequest -Uri $AssetURL -OutFile $Asset -ExpectedSha256 $hashMatch.Groups[1].Value
	Expand-Archive $Asset 'miktexsetup'
	& 'miktexsetup\miktexsetup_standalone.exe' --verbose "--package-set=$PackageSet" download
	& 'miktexsetup\miktexsetup_standalone.exe' --verbose "--package-set=$PackageSet" "--portable=$ToolDir" install
	[System.IO.File]::WriteAllText("$ToolDir\texmfs\config\miktex\config\issues.json", '[]')
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path $ToolDir -Recurse -Include 'latex.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		latex -version
	}
}
