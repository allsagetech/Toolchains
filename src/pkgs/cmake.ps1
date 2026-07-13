<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'cmake'
}

function global:Install-TlcPackage {
	$Page = Invoke-TlcWebRequest -Uri 'https://cmake.org/download/'
	$Content = $Page.Content

	$Match = [regex]::Match($Content, 'Latest Release\s*\((\d+\.\d+\.\d+)\)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
	if (-not $Match.Success) {
		Write-Error "Failed to determine latest CMake version from https://cmake.org/download/"
		return
	}
	$VersionString = $Match.Groups[1].Value
	$ZipName = "cmake-$VersionString-windows-x86_64.zip"

	$Start = $Content.IndexOf("Latest Release ($VersionString)")
	if ($Start -lt 0) { $Start = 0 }
	$Tail = $Content.Substring($Start)

	$UrlPattern = 'href="([^"]*' + [regex]::Escape($ZipName) + ')"'
	$Url = $null
	$M = [regex]::Match($Tail, $UrlPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
	if ($M.Success) { $Url = $M.Groups[1].Value }
	if (-not $Url) {
		$M2 = [regex]::Match($Content, $UrlPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
		if ($M2.Success) { $Url = $M2.Groups[1].Value }
	}
	if (-not $Url) {
		Write-Error "Failed to find CMake Windows x86_64 ZIP link on https://cmake.org/download/ (expected: $ZipName)"
		return
	}

	if ($Url -notmatch '^https?://') {
		$Url = "https://cmake.org$Url"
	}

	$Version = [TlcSemanticVersion]::new($VersionString)
	$TlcPackageConfig.UpToDate = -not $Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}

	$checksumUrl = ([Uri]::new([Uri]$Url, "cmake-$VersionString-SHA-256.txt")).AbsoluteUri
	$expectedSha256 = Get-TlcRemoteSha256 -ChecksumUri $checksumUrl -AssetName $ZipName
	Install-BuildTool -AssetName $ZipName -AssetURL $Url -ExpectedSha256 $expectedSha256
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'cmake.exe' | Select-Object -First 1).DirectoryName
		}
	}
}


function global:Test-TlcPackageInstall {
	Get-Content (Get-TlcPkgPath '.tlc')
}
