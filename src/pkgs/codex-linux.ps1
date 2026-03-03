<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'codex-linux'
}

function global:Install-TlcPackage {
	$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
	if ($isWindowsHost) {
		$TlcPackageConfig.Version = if ($TlcPackageConfig.Latest) { $TlcPackageConfig.Latest.ToString() } else { '0.0.0' }
		$TlcPackageConfig.UpToDate = $true
		Write-Host 'Skipping codex-linux package build on Windows hosts.'
		return
	}

	$latestInfo = Invoke-TlcRestMethod -Uri 'https://registry.npmjs.org/@openai%2Fcodex/latest'
	$version = [string]$latestInfo.version
	if (-not $version) {
		throw 'Could not determine the latest @openai/codex version from npm.'
	}

	$TlcPackageConfig.Version = $version
	$TlcPackageConfig.UpToDate = -not ([TlcSemanticVersion]::new($version).LaterThan($TlcPackageConfig.Latest))
	if ($TlcPackageConfig.UpToDate) {
		return
	}

	$pkgRoot = Get-TlcPkgRoot
	New-Item -ItemType Directory -Path $pkgRoot -Force | Out-Null

	$nodeTag = Get-GitHubTag -Owner 'nodejs' -Repo 'node' -TagPattern '^v(22)\.([0-9]+)\.([0-9]+)$'
	$nodeAssetName = "node-$($nodeTag.Name)-linux-x64.tar.xz"
	$nodeAssetUrl = "https://nodejs.org/dist/$($nodeTag.Name)/$nodeAssetName"

	$nodeArchive = Join-Path $env:TEMP $nodeAssetName
	Invoke-TlcWebRequest -Uri $nodeAssetUrl -OutFile $nodeArchive

	$stageRoot = if ($env:TLC_STAGE_ROOT) { $env:TLC_STAGE_ROOT } else { Join-Path $env:TEMP ("toolchains-codex-linux-" + [Guid]::NewGuid().ToString('n')) }
	$reuseStageRoot = -not [string]::IsNullOrWhiteSpace($env:TLC_STAGE_ROOT)
	if (-not $reuseStageRoot -and (Test-Path $stageRoot)) {
		Remove-Item -Recurse -Force $stageRoot
	}
	New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

	try {
		& tar -xf $nodeArchive -C $stageRoot
		if ($LASTEXITCODE -ne 0) {
			throw "Failed to extract Node.js archive: $nodeArchive"
		}

		$nodeRoot = Get-ChildItem -Path $stageRoot -Directory -Filter 'node-v*-linux-x64' | Select-Object -First 1
		if (-not $nodeRoot) {
			throw "Could not find extracted Node.js folder under $stageRoot"
		}

		$nodeBin = Join-Path $nodeRoot.FullName 'bin'
		$npmCmd = Join-Path $nodeBin 'npm'
		if (-not (Test-Path $npmCmd)) {
			throw "Could not find npm in $nodeBin"
		}

		$installRoot = Join-Path $pkgRoot 'codex'
		if (Test-Path $installRoot) {
			Remove-Item -Recurse -Force $installRoot
		}
		New-Item -ItemType Directory -Path $installRoot -Force | Out-Null

		$env:npm_config_prefix = $installRoot
		$env:npm_config_cache = Join-Path $env:TEMP 'toolchains-npm-cache'
		$sep = [System.IO.Path]::PathSeparator
		$env:Path = "$nodeBin$sep$env:Path"

		& $npmCmd install -g "@openai/codex@$version"
		if ($LASTEXITCODE -ne 0) {
			throw "npm install -g @openai/codex@$version failed with exit code $LASTEXITCODE."
		}

		$installBin = Join-Path $installRoot 'bin'
		$codexCmd = Join-Path $installBin 'codex'
		if (-not (Test-Path $codexCmd)) {
			throw "Could not find codex executable in $installBin after npm install."
		}

		Write-TlcVars @{
			env = @{
				path = @(
					$installBin
					$nodeBin
				)
			}
		}
	}
	finally {
		if (-not $reuseStageRoot -and (Test-Path $stageRoot)) {
			Remove-Item -Recurse -Force $stageRoot -ErrorAction SilentlyContinue
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		codex --version
		node --version
		npm --version
	}
}
