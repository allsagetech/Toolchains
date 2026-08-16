<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'go'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'golang'
		Repo = 'go'
		TagPattern = '^go([0-9]+)\.([0-9]+)\.?([0-9]+)?$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$AssetName = "$Tag.windows-amd64.zip"
	$goRelease = Invoke-TlcRestMethod -Uri 'https://go.dev/dl/?mode=json'
	$goFile = @($goRelease.files) | Where-Object { [string]$_.filename -eq $AssetName } | Select-Object -First 1
	if (-not $goFile -or [string]$goFile.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "Go release metadata is missing SHA-256 for $AssetName" }
	$Params = @{
		AssetName = $AssetName
		AssetURL = "https://go.dev/dl/$AssetName"
		ExpectedSha256 = [string]$goFile.sha256
	}
	Install-BuildTool @Params
	$goBinary = Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'go.exe' | Select-Object -First 1
	if (-not $goBinary) { throw 'Go archive did not contain go.exe.' }
	$goRoot = Split-Path -Parent $goBinary.DirectoryName
	$testPrivateKey = Join-Path $goRoot 'src/crypto/x509/platform_root_key.pem'
	if (Test-Path -LiteralPath $testPrivateKey -PathType Leaf) {
		Remove-Item -LiteralPath $testPrivateKey -Force
	}
	if (Test-Path -LiteralPath $testPrivateKey) { throw 'Go crypto/x509 test private key remained in the package payload.' }
	Write-TlcVars @{
		env = @{
			path = $goBinary.DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		go version
	}
}
