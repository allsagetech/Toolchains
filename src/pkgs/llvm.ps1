<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'llvm'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner        = 'llvm'
		Repo         = 'llvm-project'
		AssetPattern = '^LLVM-.+-win64\.exe$'
		TagPattern   = '^llvmorg-([0-9]+)\.([0-9]+)\.([0-9]+)$'
	}
	$Asset = Get-GitHubRelease @Params
	$TlcPackageConfig.UpToDate = -not $Asset.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Asset.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}

	if (-not (Test-Path '\pkg')) { New-Item -ItemType Directory -Path '\pkg' -Force | Out-Null }
	$pkgRoot = (Resolve-Path '\pkg').Path

	$llvmExe = Join-Path $env:TEMP $Asset.Name
	Invoke-TlcWebRequest -Uri $Asset.URL -OutFile $llvmExe

	$installDir = Join-Path $pkgRoot ("llvm-" + $TlcPackageConfig.Version)

	if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir }

	$psi = @{
		FilePath     = $llvmExe
		ArgumentList = @("/S", "/D=$installDir")
		Wait         = $true
		NoNewWindow  = $true
		PassThru     = $true
	}
	$p = Start-Process @psi
	if ($p.ExitCode -ne 0) {
		throw "LLVM installer exited with code $($p.ExitCode)"
	}

	$bin = Join-Path $installDir 'bin'
	if (-not (Test-Path (Join-Path $bin 'clang.exe'))) {
		$found = Get-ChildItem -Path $installDir -Recurse -Filter 'clang.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
		if (-not $found) { throw "clang.exe not found after LLVM install in $installDir" }
		$bin = $found.DirectoryName
	}

	Write-TlcVars @{
		env = @{
			path = $bin
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		clang --version
	}
}
