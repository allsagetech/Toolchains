<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot

function Assert-True {
	param(
		[Parameter(Mandatory=$true)][bool]$Condition,
		[Parameter(Mandatory=$true)][string]$Message
	)

	if (-not $Condition) {
		throw $Message
	}
}

function Test-PowerShellSyntax {
	$files = Get-ChildItem -Path $repoRoot -Filter '*.ps1' -Recurse -File | Sort-Object FullName
	foreach ($file in $files) {
		$tokens = $null
		$errors = $null
		[System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
		if ($errors.Count -gt 0) {
			$text = ($errors | ForEach-Object { "$($_.Extent.File):$($_.Extent.StartLineNumber):$($_.Message)" }) -join [Environment]::NewLine
			throw "PowerShell parse failed for $($file.FullName):$([Environment]::NewLine)$text"
		}
	}
	Write-Host "Parsed $($files.Count) PowerShell scripts."
}

function Test-PackageScripts {
	. .\src\main.ps1

	$allowedTiers = @('tooling', 'model-small', 'model-large')
	$packages = Get-ChildItem -Path .\src\pkgs -Filter '*.ps1' -Recurse -File | Sort-Object FullName
	Assert-True ($packages.Count -gt 0) 'No package scripts found under src/pkgs.'

	foreach ($package in $packages) {
		Clear-TlcPackageScript
		& $package.FullName
		Test-TlcPackageScript

		$tier = if ($TlcPackageConfig.Tier) { [string]$TlcPackageConfig.Tier } else { 'tooling' }
		Assert-True ($tier -in $allowedTiers) "Package $($package.FullName) has unsupported tier: $tier"

		$runsOn = Get-TlcPackageRunsOn
		if ($tier -like 'model-*') {
			Assert-True (Test-TlcRunsOnUbuntu -RunsOn $runsOn) "Model package $($TlcPackageConfig.Name) must run on an Ubuntu runner."
		}
	}

	Clear-TlcPackageScript
	Write-Host "Validated $($packages.Count) package scripts."
}

function Test-HuggingFaceHelpers {
	. .\src\main.ps1

	Assert-True ((Get-TlcHfModelCacheSlug -Repo 'Qwen/Qwen3-0.6B') -eq 'models--Qwen--Qwen3-0.6B') 'HF cache slug helper returned an unexpected value.'

	$patterns = @(Get-TlcHfModelAllowPatterns)
	foreach ($pattern in @('config.json', 'tokenizer.json', 'model-*.safetensors', '*.safetensors.index.json')) {
		Assert-True ($patterns -contains $pattern) "Default HF allow patterns are missing $pattern."
	}

	Write-Host 'Validated Hugging Face helper defaults.'
}

function Test-WorkflowRunnerDefaults {
	. .\src\main.ps1

	Assert-True ((Get-TlcDefaultWindowsRunner) -eq 'windows-2022') 'Default Windows package runner should stay on GitHub-hosted windows-2022.'

	$runner = @(Get-TlcDefaultWindowsDockerRunner)
	foreach ($label in @('self-hosted', 'windows', 'x64', 'toolchains-windows-docker')) {
		Assert-True ($runner -contains $label) "Default Windows Docker runner is missing label: $label"
	}
	Assert-True (-not (Test-TlcRunsOnUbuntu -RunsOn $runner)) 'Default Windows Docker runner was incorrectly detected as Ubuntu.'
	Assert-True (Test-TlcRunsOnUbuntu -RunsOn 'ubuntu-latest') 'Ubuntu runner detection failed.'

	Clear-TlcPackageScript
	$global:TlcPackageConfig = @{ Name = 'test-package' }
	Assert-True ((Get-TlcPackageRunsOn) -eq 'windows-2022') 'Package install/test default runner should be windows-2022.'
	Assert-True (@(Get-TlcPackagePublishRunsOn) -contains 'toolchains-windows-docker') 'Package publish default runner should be the Windows Docker runner.'
	Clear-TlcPackageScript

	$workflow = Get-Content -LiteralPath '.github/workflows/build-push.yml' -Raw
	Assert-True ($workflow -match 'ENABLE_WINDOWS_DOCKER_PUBLISH') 'Workflow is missing the Windows Docker publish gate.'
	Assert-True ($workflow -match 'Test-TlcRunsOnUbuntu -RunsOn \$_.publish_runs_on') 'Workflow does not filter disabled Windows Docker publish jobs.'

	Write-Host 'Validated workflow runner defaults.'
}

function Test-HuggingFaceLayeredDockerfile {
	. .\src\main.ps1

	$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("toolchains-hf-layer-test-" + [Guid]::NewGuid().ToString('n'))
	$oldPkgRoot = $env:TLC_PKG_ROOT
	$oldConfig = $global:TlcPackageConfig
	try {
		$env:TLC_PKG_ROOT = $tempRoot
		$global:TlcPackageConfig = @{
			Name = 'test-model'
			Version = '1.0.0'
		}

		$cacheSlug = 'models--Example--Tiny'
		$modelRoot = Join-Path $tempRoot "cache/hf-cache/$cacheSlug"
		foreach ($path in @(
			$tempRoot,
			(Join-Path $modelRoot 'refs'),
			(Join-Path $modelRoot 'snapshots/main'),
			(Join-Path $modelRoot 'blobs')
		)) {
			New-Item -ItemType Directory -Path $path -Force | Out-Null
		}

		Set-Content -LiteralPath (Join-Path $tempRoot '.tlc') -Value '{"env":{}}' -NoNewline
		Set-Content -LiteralPath (Join-Path $tempRoot 'official-models.manifest.json') -Value '{"models":[{"cache_slug":"models--Example--Tiny"}]}' -NoNewline
		Set-Content -LiteralPath (Join-Path $modelRoot 'refs/main') -Value 'main' -NoNewline
		Set-Content -LiteralPath (Join-Path $modelRoot 'snapshots/main/config.json') -Value '{}' -NoNewline
		Set-Content -LiteralPath (Join-Path $modelRoot 'blobs/abc123') -Value 'blob' -NoNewline

		$dockerfilePath = Write-HfModelLayeredDockerfile -PkgRoot $tempRoot -CacheRoot (Join-Path $tempRoot 'cache/hf-cache') -CacheSlug $cacheSlug
		Assert-True (Test-Path -LiteralPath $dockerfilePath -PathType Leaf) 'Layered HF Dockerfile was not created.'
		Assert-True (Test-Path -LiteralPath (Join-Path $tempRoot '.dockerignore') -PathType Leaf) 'HF model .dockerignore was not created.'

		$dockerfile = Get-Content -LiteralPath $dockerfilePath -Raw
		Assert-True ($dockerfile -match 'COPY "official-models\.manifest\.json" "/official-models\.manifest\.json"') 'Layered Dockerfile does not copy the model manifest.'
		Assert-True ($dockerfile -match 'cache/hf-cache/models--Example--Tiny/blobs/abc123') 'Layered Dockerfile does not copy individual model blobs.'
		Assert-True ($dockerfile -match 'cache/hf-cache/models--Example--Tiny/snapshots') 'Layered Dockerfile does not copy model snapshots.'

		Write-Host 'Validated Hugging Face layered Dockerfile generation.'
	}
	finally {
		$env:TLC_PKG_ROOT = $oldPkgRoot
		$global:TlcPackageConfig = $oldConfig
		if (Test-Path -LiteralPath $tempRoot) {
			Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
		}
	}
}

Test-PowerShellSyntax
Test-PackageScripts
Test-HuggingFaceHelpers
Test-HuggingFaceLayeredDockerfile
Test-WorkflowRunnerDefaults
