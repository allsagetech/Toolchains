<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'lmstudio'
	BuildRevision = 1
	NpmVersion = '12.0.2'
	NpmExpectedSha512 = 'b885e890b9418fa1693544d05f53e64f9a73ec194837d4258b15fecdd692347b1dd2a517b1b0cbaf9d31cd8e92c3b70956bd2ecc72833a57b4b3098f5bfa7943'
	NpmDependencyOverlays = @{
		'brace-expansion' = @{
			Version = '5.0.9'
			ExpectedSha512 = '49c43822ebc8105d533253fb66dfaf8c9ffff7394f6f64837315b13376e4f2ceade8619d27b28ed5d09c4e274e3c929e3d6df42c4ff6713ef00b23e1a3dfd6c6'
		}
		'ip-address' = @{
			Version = '10.5.0'
			ExpectedSha512 = '4794a754b26681862f7f6176660c120677a5cf91b8ab9031202dbbec60df51a35bad928d00d7010bb447a9861e3e5b337f8901a2556425ab86d198c71c5879e6'
		}
	}
}

function global:Install-TlcPackage {

    if (-not $env:TLC_PKG_ROOT) {
        throw 'TLC_PKG_ROOT is not set; cannot determine install root for lmstudio.'
    }

    $latestInfo = Invoke-TlcRestMethod -Uri 'https://registry.npmjs.org/lmstudio/latest'
    $version = [string]$latestInfo.version
    if (-not $version) {
        throw 'Could not determine the latest lmstudio version from npm.'
    }

    $packageVersion = Add-TlcPackagingRevision -Version $version -Revision ([int]$TlcPackageConfig.BuildRevision)
    $TlcPackageConfig.Version = $packageVersion
    $TlcPackageConfig.UpToDate = -not ([TlcSemanticVersion]::new($packageVersion).LaterThan($TlcPackageConfig.Latest))
    if ($TlcPackageConfig.UpToDate) {
        return
    }

    $nodeTag = Get-GitHubTag -Owner 'nodejs' -Repo 'node' -TagPattern '^v(22)\.([0-9]+)\.([0-9]+)$'
    $nodeAssetName = "node-$($nodeTag.Name)-win-x64.zip"
    Install-BuildTool -AssetName $nodeAssetName -AssetURL "https://nodejs.org/dist/$($nodeTag.Name)/$nodeAssetName"

    $nodeRoot = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'node.exe' | Select-Object -First 1).DirectoryName
    if (-not $nodeRoot) {
        throw 'Could not find node.exe after extracting the Node.js archive.'
    }

	$npmRoot = Join-Path $nodeRoot 'node_modules\npm'
	Install-TlcPinnedNpmArchive -Name 'npm' -Version $TlcPackageConfig.NpmVersion `
		-ExpectedSha512 $TlcPackageConfig.NpmExpectedSha512 -Destination $npmRoot
	foreach ($dependencyName in @($TlcPackageConfig.NpmDependencyOverlays.Keys | Sort-Object)) {
		$overlay = $TlcPackageConfig.NpmDependencyOverlays[$dependencyName]
		Install-TlcPinnedNpmArchive -Name $dependencyName -Version $overlay.Version `
			-ExpectedSha512 $overlay.ExpectedSha512 -Destination (Join-Path $npmRoot "node_modules\$dependencyName")
	}

    $npmCmd = Join-Path $nodeRoot 'npm.cmd'
    if (-not (Test-Path $npmCmd)) {
        throw "Could not find npm.cmd in $nodeRoot"
    }

    $installRoot = Join-Path $env:TLC_PKG_ROOT 'lmstudio'
    if (-not (Test-Path $installRoot)) {
        New-Item -ItemType Directory -Path $installRoot | Out-Null
    }

    $env:npm_config_prefix = $installRoot
    $env:npm_config_cache = Join-Path $env:TEMP 'toolchains-npm-cache'
    $env:Path = "$nodeRoot;$env:Path"

    & $npmCmd install -g "lmstudio@$version"
    if ($LASTEXITCODE -ne 0) {
        throw "npm install -g lmstudio@$version failed with exit code $LASTEXITCODE."
    }

    $lmstudioCmd = Join-Path $installRoot 'lmstudio.cmd'
    if (-not (Test-Path $lmstudioCmd)) {
        throw "Could not find lmstudio.cmd in $installRoot after npm install."
    }

    Write-TlcVars @{
        env = @{
            path = "$installRoot;$nodeRoot"
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
		$lmstudioShim = Get-Command 'lmstudio.cmd' -CommandType Application -ErrorAction Stop | Select-Object -First 1
		$lmstudioRoot = Join-Path (Split-Path -Parent $lmstudioShim.Source) 'node_modules\lmstudio'
		$manifestPath = Join-Path $lmstudioRoot 'package.json'
		if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
			throw "LM Studio package manifest not found: $manifestPath"
		}
		$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
		if ([string]$manifest.name -ne 'lmstudio') {
			throw "Unexpected LM Studio package name in manifest: $($manifest.name)"
		}
		$binEntry = if ($manifest.bin -is [string]) {
			[string]$manifest.bin
		} else {
			$lmstudioBinProperty = $manifest.bin.PSObject.Properties['lmstudio']
			if ($lmstudioBinProperty) { [string]$lmstudioBinProperty.Value }
		}
		if ([string]::IsNullOrWhiteSpace($binEntry)) {
			throw 'LM Studio package manifest does not expose the expected CLI shim.'
		}
		$entrypoint = Join-Path $lmstudioRoot $binEntry
		if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
			throw "LM Studio CLI entrypoint not found: $entrypoint"
		}
		node --check $entrypoint
		if ($LASTEXITCODE -ne 0) { throw "LM Studio CLI syntax check failed with exit code $LASTEXITCODE." }
		npm --version
    }
}
