<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'git-linux'
}

function global:Install-TlcPackage {
	$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
	if ($isWindowsHost) {
		$TlcPackageConfig.Version = if ($TlcPackageConfig.Latest) { $TlcPackageConfig.Latest.ToString() } else { '0.0.0' }
		$TlcPackageConfig.UpToDate = $true
		Write-Host 'Skipping git-linux package build on Windows hosts.'
		return
	}

	$gitCommand = Get-Command git -ErrorAction SilentlyContinue
	if (-not $gitCommand) {
		throw 'git is required on PATH to build git-linux package metadata.'
	}

	$gitVersionText = (& $gitCommand.Source --version | Out-String).Trim()
	if ($gitVersionText -notmatch '([0-9]+)\.([0-9]+)\.([0-9]+)') {
		throw "Could not parse git version from output: $gitVersionText"
	}
	$version = "$($Matches[1]).$($Matches[2]).$($Matches[3])"

	$TlcPackageConfig.Version = $version
	$TlcPackageConfig.UpToDate = -not ([TlcSemanticVersion]::new($version).LaterThan($TlcPackageConfig.Latest))
	if ($TlcPackageConfig.UpToDate) {
		return
	}

	Write-TlcVars @{
		env = @{
			path = @(
				'/usr/bin'
				'/bin'
			)
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		git --version
		curl --version
		sed --version
	}
}
