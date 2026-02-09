
<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'vcpkg'
}

function global:Install-TlcPackage {
	$params = @{
		Owner = 'Microsoft'
		Repo = 'vcpkg'
		TagPattern = '^([0-9]+)\.([0-9]+)\.([0-9]+)$'
	}
	$latest = Get-GitHubTag @params
	$global:TlcPackageConfig.UpToDate = -not $latest.Version.LaterThan($global:TlcPackageConfig.Latest)
	$global:TlcPackageConfig.Version = $latest.Version.ToString()
	if ($global:TlcPackageConfig.UpToDate) {
		return
	}
	$url = "https://github.com/microsoft/vcpkg.git"
	$v = "{0:D4}.{1:D2}.{2:D2}" -f $latest.Version.Major, $latest.Version.Minor, $latest.Version.Patch
	$vcpkgRoot = Join-Path (Get-TlcPkgRoot) 'vcpkg'
	if (Test-Path $vcpkgRoot) { Remove-Item -Recurse -Force $vcpkgRoot }
	git.exe clone --separate-git-dir '.git.vcpkg' --depth 1 --branch $v $url $vcpkgRoot
	if ($LASTEXITCODE -ne 0) {
		throw "git clone --separate-git-dir '.git.vcpkg' --depth 1 --branch $v $url $vcpkgRoot exit code $LASTEXITCODE"
	}
	Write-Host "installing vcpkg $v"
	Push-Location $vcpkgRoot
	.\bootstrap-vcpkg.bat -disableMetrics
	Get-ChildItem .
	Pop-Location
	Write-TlcVars @{
		env = @{
			vcpkg_root = $vcpkgRoot
			path = (Get-ChildItem -Path $vcpkgRoot -Recurse -Include 'vcpkg.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		vcpkg.exe --version
	}
}
