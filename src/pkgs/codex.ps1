<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'codex'
	Upstream = 'https://github.com/openai/codex'
}

function global:Install-TlcPackage {
	$asset = Get-GitHubRelease -Owner 'openai' -Repo 'codex' `
		-AssetPattern '^codex-package-x86_64-pc-windows-msvc\.tar\.gz$' `
		-TagPattern '^rust-v([0-9]+)\.([0-9]+)\.([0-9]+)$'
	$TlcPackageConfig.Version = $asset.Version.ToString()
	$TlcPackageConfig.UpToDate = -not $asset.Version.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }
	if (-not $asset.ExpectedSha256) {
		throw "No GitHub-published SHA-256 was available for $($asset.Name)."
	}

	$archivePath = Get-TlcStagingPath $asset.Name
	Invoke-TlcWebRequest -Uri $asset.URL -OutFile $archivePath -ExpectedSha256 $asset.ExpectedSha256 | Out-Null
	$tar = Get-TlcApplicationPath -Name 'tar'
	$entries = @(& $tar '-tzf' $archivePath)
	if ($LASTEXITCODE -ne 0 -or $entries.Count -eq 0) {
		throw "Could not list verified Codex archive $($asset.Name)."
	}
	foreach ($entry in $entries) {
		$normalized = ([string]$entry).Replace('\', '/')
		$segments = @($normalized.Split('/') | Where-Object { $_ })
		if ($segments -contains '..' -or $normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:' -or $normalized.IndexOf([char]0) -ge 0) {
			throw "Codex archive $($asset.Name) contains an unsafe path: $entry"
		}
	}
	$details = @(& $tar '-tvzf' $archivePath)
	if ($LASTEXITCODE -ne 0) { throw "Could not inspect verified Codex archive $($asset.Name)." }
	if (@($details | Where-Object { $_.TrimStart() -match '^[lh]' }).Count -gt 0) {
		throw "Codex archive $($asset.Name) contains links, which are not permitted."
	}

	$packageRoot = Get-TlcPkgRoot
	New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
	& $tar '-xzf' $archivePath '-C' $packageRoot
	if ($LASTEXITCODE -ne 0) { throw "Failed to extract $($asset.Name) with exit code $LASTEXITCODE." }

	$manifestPath = Join-Path $packageRoot 'codex-package.json'
	if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
		throw 'The verified Codex package did not contain codex-package.json.'
	}
	$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
	if ([int]$manifest.layoutVersion -ne 1 -or [string]$manifest.version -cne $asset.Version.ToString() -or
		[string]$manifest.target -cne 'x86_64-pc-windows-msvc' -or [string]$manifest.variant -cne 'codex' -or
		[string]$manifest.entrypoint -cne 'bin/codex.exe' -or [string]$manifest.resourcesDir -cne 'codex-resources' -or
		[string]$manifest.pathDir -cne 'codex-path') {
		throw "Codex package identity mismatch for $($asset.Name)."
	}
	foreach ($requiredPath in @(
		'bin\codex.exe',
		'bin\codex-code-mode-host.exe',
		'codex-path\rg.exe',
		'codex-resources\codex-command-runner.exe',
		'codex-resources\codex-windows-sandbox-setup.exe'
	)) {
		if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $requiredPath) -PathType Leaf)) {
			throw "The verified Codex package did not contain $requiredPath."
		}
	}

	Write-TlcVars @{
		env = @{
			path = "$(Join-Path $packageRoot 'bin');$(Join-Path $packageRoot 'codex-path')"
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		codex --version
		codex --help
	}
}
