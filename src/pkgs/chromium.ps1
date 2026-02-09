<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'chromium'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'ungoogled-software'
		Repo = 'ungoogled-chromium-windows'
		AssetPattern = 'ungoogled-chromium_.*_windows_x64\.zip$'
		TagPattern = '^([0-9]+)\.([0-9]+)\.([0-9]+)(\.[0-9]+)(-.+)?$'
	}
	$Asset = Get-GitHubRelease @Params
	$TlcPackageConfig.UpToDate = -not $Asset.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Asset.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Params = @{
		AssetName = $Asset.Name
		AssetURL = $Asset.URL
	}
	Install-BuildTool @Params
	$pkgRoot = if ($env:TLC_PKG_ROOT) { $env:TLC_PKG_ROOT } else { '\pkg' }
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path $pkgRoot -Recurse -Include 'chrome.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	$pkgRoot = if ($env:TLC_PKG_ROOT) { $env:TLC_PKG_ROOT } else { '\\pkg' }
	$chromeExe = Get-ChildItem -Path $pkgRoot -Recurse -Filter 'chrome.exe' | Select-Object -First 1
	if (-not $chromeExe) { throw "chrome.exe not found under $pkgRoot" }

	& $chromeExe.FullName --headless --disable-gpu --dump-dom https://github.com/ungoogled-software/ungoogled-chromium-windows/releases/latest | Out-Null
}
