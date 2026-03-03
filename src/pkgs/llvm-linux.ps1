<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'llvm-linux'
}

function global:Install-TlcPackage {
	$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
	if ($isWindowsHost) {
		$TlcPackageConfig.Version = if ($TlcPackageConfig.Latest) { $TlcPackageConfig.Latest.ToString() } else { '0.0.0' }
		$TlcPackageConfig.UpToDate = $true
		Write-Host 'Skipping llvm-linux package build on Windows hosts.'
		return
	}

	$params = @{
		Owner        = 'llvm'
		Repo         = 'llvm-project'
		AssetPattern = '^clang\+llvm-.+-x86_64-linux-gnu.*\.tar\.xz$'
		TagPattern   = '^llvmorg-([0-9]+)\.([0-9]+)\.([0-9]+)$'
	}
	$asset = Get-GitHubRelease @params
	$TlcPackageConfig.UpToDate = -not $asset.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $asset.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}

	$pkgRoot = Get-TlcPkgRoot
	New-Item -ItemType Directory -Path $pkgRoot -Force | Out-Null

	$llvmTar = Join-Path $env:TEMP $asset.Name
	Invoke-TlcWebRequest -Uri $asset.URL -OutFile $llvmTar

	$installDir = Join-Path $pkgRoot ("llvm-" + $TlcPackageConfig.Version)
	if (Test-Path $installDir) {
		Remove-Item -Recurse -Force $installDir
	}
	New-Item -ItemType Directory -Path $installDir -Force | Out-Null

	& tar -xf $llvmTar -C $installDir --strip-components=1
	if ($LASTEXITCODE -ne 0) {
		& tar -xf $llvmTar -C $installDir
		if ($LASTEXITCODE -ne 0) {
			throw "Failed to extract LLVM archive: $llvmTar"
		}
	}

	$bin = Join-Path $installDir 'bin'
	if (-not (Test-Path (Join-Path $bin 'clang'))) {
		$found = Get-ChildItem -Path $installDir -Recurse -Filter 'clang' -File -ErrorAction SilentlyContinue | Select-Object -First 1
		if (-not $found) {
			throw "clang not found after LLVM install in $installDir"
		}
		$bin = $found.DirectoryName
	}

	Write-TlcVars @{
		env = @{
			path = @(
				$bin
			)
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		clang --version
	}
}
