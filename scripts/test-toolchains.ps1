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
	Assert-True (($runner.Count -eq 1) -and ($runner[0] -eq 'windows-2022')) 'Default Windows Docker runner should be GitHub-hosted windows-2022.'
	Assert-True (-not (Test-TlcRunsOnUbuntu -RunsOn $runner)) 'Default Windows Docker runner was incorrectly detected as Ubuntu.'
	Assert-True (Test-TlcRunsOnUbuntu -RunsOn 'ubuntu-latest') 'Ubuntu runner detection failed.'
	Assert-True ((Get-TlcPkgRootForRunner -RunsOn 'windows-2022') -eq 'D:\pkg') 'Windows package root should match the package scripts.'
	Assert-True ((Get-TlcCachePathForRunner -RunsOn 'windows-2022') -eq 'D:\pkg\cache') 'Windows cache path should match the package scripts.'
	Assert-True ((Get-TlcPkgRootForRunner -RunsOn 'ubuntu-latest') -eq '/mnt/toolchains-pkg') 'Ubuntu package root should use the mounted package directory.'
	Assert-True ((Get-TlcCachePathForRunner -RunsOn 'ubuntu-latest') -eq '/mnt/toolchains-pkg/cache') 'Ubuntu cache path should use the mounted cache directory.'

	Clear-TlcPackageScript
	$global:TlcPackageConfig = @{ Name = 'test-package' }
	Assert-True ((Get-TlcPackageRunsOn) -eq 'windows-2022') 'Package install/test default runner should be windows-2022.'
	Assert-True ((Get-TlcPackagePublishRunsOn) -eq 'windows-2022') 'Package publish default runner should be windows-2022.'
	Clear-TlcPackageScript

	Write-Host 'Validated workflow runner defaults.'
}

function Test-ProductionReadinessPolicies {
	. .\src\main.ps1

	$installerText = Get-Content -LiteralPath .\scripts\install-toolchain.ps1 -Raw
	Assert-True ($installerText -match "10342606bb137f6a9823a8bc8ca4f7f75a1a40d2") 'Toolchain installer default is not pinned to the reviewed immutable commit.'
	Assert-True ($installerText -notmatch "else \{ 'pipeline' \}") 'Toolchain installer still defaults to the mutable pipeline branch.'

	$hardCodedRoots = @(Get-ChildItem -Path .\src\pkgs -Filter '*.ps1' -Recurse -File | Select-String -Pattern '(?i)(?<![A-Za-z0-9_])\\{1,2}pkg(?:[\\/]|[''\"])')
	Assert-True ($hardCodedRoots.Count -eq 0) "Package scripts contain hard-coded package roots: $($hardCodedRoots.Path -join ', ')"
	$oldPolicyRoot = $env:TLC_PKG_ROOT
	try {
		$customRoot = Join-Path ([IO.Path]::GetTempPath()) 'arbitrary-toolchains-root'
		$env:TLC_PKG_ROOT = $customRoot
		Assert-True ((Get-TlcPkgRoot) -eq [IO.Path]::GetFullPath($customRoot)) 'Get-TlcPkgRoot ignored an arbitrary TLC_PKG_ROOT.'
		Assert-True ((Get-TlcPkgPath 'nested/tool') -eq (Join-Path ([IO.Path]::GetFullPath($customRoot)) 'nested/tool')) 'Get-TlcPkgPath did not resolve relative to an arbitrary TLC_PKG_ROOT.'
	} finally {
		$env:TLC_PKG_ROOT = $oldPolicyRoot
	}
	$dockerPackageText = Get-Content -LiteralPath .\src\pkgs\docker.ps1 -Raw
	Assert-True ($dockerPackageText -notmatch '\bInvoke-DockerPush\b') 'Docker package installer still owns image publication.'
	Assert-True ($dockerPackageText -notmatch 'UpToDate\s*=\s*\$true') 'Docker package installer still unconditionally suppresses lifecycle testing/publication.'
	$pushText = (Get-Command Invoke-DockerPush).Definition
	Assert-True ($pushText -match 'existing signature state was not proven') 'Requested signing can silently skip an existing image tag.'

	$notepadText = Get-Content -LiteralPath .\src\pkgs\notepadplus.ps1 -Raw
	Assert-True ($notepadText -notmatch "Matcher\s*=\s*['`"]\^npp") 'Notepad++ still uses a matcher that cannot match its published package tags.'
	foreach ($verifiedScript in @('.\src\pkgs\vscode.ps1', '.\src\pkgs\miktex.ps1')) {
		$verifiedText = Get-Content -LiteralPath $verifiedScript -Raw
		Assert-True ($verifiedText -match 'ExpectedSha256') "$verifiedScript does not pass its publisher SHA-256 to the common downloader."
	}
	Clear-TlcPackageScript
	foreach ($quarantinedScript in @('.\src\pkgs\docker.ps1', '.\src\pkgs\nasm.ps1', '.\src\pkgs\zstd.ps1')) {
		Clear-TlcPackageScript
		. $quarantinedScript
		Assert-True (-not [bool]$TlcPackageConfig.VerifiedDownloads) "$quarantinedScript is not quarantined despite missing publisher provenance metadata."
		Assert-True (-not [string]::IsNullOrWhiteSpace([string]$TlcPackageConfig.UnverifiedDownloadReason)) "$quarantinedScript quarantine does not explain the provenance gap."
	}
	$sevenZipPackageText = Get-Content -LiteralPath .\src\pkgs\7-zip.ps1 -Raw
	Assert-True ($sevenZipPackageText -match 'github\.com/ip7z/7zip/releases/download/25\.01/7z2501-x64\.exe') '7-Zip does not use the official GitHub release asset with published SHA-256 metadata.'
	$doxygenPackageText = Get-Content -LiteralPath .\src\pkgs\doxygen.ps1 -Raw
	Assert-True ($doxygenPackageText -match 'github\.com/doxygen/doxygen/releases/download/\$Tag/\$AssetName') 'Doxygen does not use its official GitHub release asset with published SHA-256 metadata.'
	$vsBuildToolsText = Get-Content -LiteralPath .\src\pkgs\vs-buildtools.ps1 -Raw
	Assert-True ($vsBuildToolsText.Contains('${env:ProgramFiles(x86)}\Microsoft SDKs')) 'Visual Studio Build Tools omits an SDK directory referenced by its generated PATH contract.'
	$utilText = Get-Content -LiteralPath .\src\util.ps1 -Raw
	Assert-True ($utilText -match '\$assetName\.sha256\.txt') 'GitHub release verification does not discover publisher companion SHA-256 assets.'
	$workflowText = Get-Content -LiteralPath .\.github\workflows\build-push.yml -Raw
	Assert-True ($workflowText -match '\$TlcPackageConfig\.Tags\s*=\s*@\(\)') 'Forced PR smoke builds do not clear published package tags.'
	Assert-True ($workflowText -match 'Where-Object \{ \[bool\]\$_\.verified_downloads -and \[bool\]\$_\.publish_eligible \}') 'Workflow matrices do not exclude unverified or quarantined packages.'
	Assert-True (([regex]::Matches($workflowText, 'GH_TOKEN:\s+\$\{\{ github\.token \}\}')).Count -ge 4) 'Parallel build jobs do not authenticate GitHub API requests.'
	Assert-True ($workflowText -match 'RUNNER_OS -eq ''Linux''[\s\S]+Get-ChildItem -LiteralPath \$full -Force \| Remove-Item') 'Linux package cleanup still removes the protected mount root.'
	foreach ($optionalX86Script in @(
		'.\src\pkgs\jdk\jdk8.ps1', '.\src\pkgs\jdk\jdk11.ps1', '.\src\pkgs\jdk\jdk17.ps1',
		'.\src\pkgs\jre\jre8.ps1', '.\src\pkgs\jre\jre11.ps1', '.\src\pkgs\jre\jre17.ps1'
	)) {
		$optionalX86Text = Get-Content -LiteralPath $optionalX86Script -Raw
		Assert-True ($optionalX86Text -match 'Not Found\|no upstream hash') "$optionalX86Script does not skip an unavailable optional x86 artifact under strict verification."
	}
	Clear-TlcPackageScript

	$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("toolchains-ignore-test-" + [Guid]::NewGuid().ToString('n'))
	try {
		New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
		Set-Content -LiteralPath (Join-Path $tempRoot '.dockerignore') -Value 'keep-me' -NoNewline
		Set-TlcPackageDockerignore -PkgRoot $tempRoot
		$ignore = @(Get-Content -LiteralPath (Join-Path $tempRoot '.dockerignore'))
		Assert-True ($ignore -contains 'keep-me') 'Package .dockerignore generation overwrote package-specific entries.'
		Assert-True ($ignore -contains 'cache') 'Package .dockerignore does not exclude the download cache.'
		Assert-True ($ignore -contains '_stage') 'Package .dockerignore does not exclude package staging content.'
		Assert-True ($ignore -contains '_stage/**') 'Package .dockerignore does not recursively exclude package staging content.'
		Assert-True ($ignore -contains '**/*.partial-*') 'Package .dockerignore does not exclude partial downloads.'
	} finally {
		Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	$validEnv = [pscustomobject]@{ PATH = 'bin'; REMOVE_ME = $null }
	Assert-True (Test-TlcEnvMap -EnvMap $validEnv) 'Environment validation rejected null remove/unset semantics.'
	$blankRejected = $false
	try { Test-TlcEnvMap -EnvMap ([hashtable]@{ ' ' = 'value' }) | Out-Null } catch { $blankRejected = $true }
	Assert-True $blankRejected 'Environment validation accepted a blank variable name.'

	$dockerBuildText = (Get-Command Invoke-DockerBuild).Definition
	Assert-True ($dockerBuildText -match 'Assert-TlcDefinitionFile') 'Docker builds do not validate the .tlc definition before custom build dispatch.'
	Assert-True ($dockerBuildText -match 'Assert-TlcBuiltImageContract') 'Docker builds do not enforce required labels after custom builds.'
	$vsCustomBuild = Get-Content -LiteralPath .\src\pkgs\vs-buildtools.ps1 -Raw
	Assert-True ($vsCustomBuild -match 'foreach\s*\(\s*\$label\s+in\s+\$labels\s*\)') 'Visual Studio custom image build does not apply common contract labels.'
	$matrixText = (Get-Command Save-WorkflowMatrix).Definition
	foreach ($field in @('verified_downloads', 'publish_eligible', 'unverified_download_reason')) {
		Assert-True ($matrixText -match $field) "Workflow matrix does not expose provenance field $field."
	}
	try {
		$global:TlcTestDockerLabelJson = '{"io.allsagetech.toolchain.specVersion":"1","toolchain.tlcPath":"/.tlc"}'
		function global:docker {
			param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Remaining)
			$global:LASTEXITCODE = 0
			return $global:TlcTestDockerLabelJson
		}
		Assert-TlcBuiltImageContract -Tag 'test:contract' -ExpectedLabels @('io.allsagetech.toolchain.specVersion=1', 'toolchain.tlcPath=/.tlc')
		$global:TlcTestDockerLabelJson = '{"io.allsagetech.toolchain.specVersion":"1"}'
		$missingLabelRejected = $false
		try { Assert-TlcBuiltImageContract -Tag 'test:contract' -ExpectedLabels @('toolchain.tlcPath=/.tlc') } catch { $missingLabelRejected = $true }
		Assert-True $missingLabelRejected 'Post-build image contract accepted a missing required label.'
	} finally {
		Remove-Item Function:\global:docker -Force -ErrorAction SilentlyContinue
		Remove-Variable TlcTestDockerLabelJson -Scope Global -Force -ErrorAction SilentlyContinue
	}

	Write-Host 'Validated production-readiness policy regressions.'
}

function Test-AtomicVerifiedDownloads {
	. .\src\main.ps1

	$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("toolchains-download-test-" + [Guid]::NewGuid().ToString('n'))
	$oldCacheRoot = $env:TLC_CACHE_ROOT
	$oldRequireVerified = $env:TLC_REQUIRE_VERIFIED_DOWNLOADS
	$sourcePath = Join-Path $tempRoot 'source.bin'
	$destination = Join-Path $tempRoot 'destination.bin'
	$global:TlcTestDownloadCalls = 0
	try {
		New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
		[IO.File]::WriteAllText($sourcePath, 'trusted payload')
		$expected = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
		$env:TLC_CACHE_ROOT = Join-Path $tempRoot 'cache'
		$env:TLC_REQUIRE_VERIFIED_DOWNLOADS = '1'

		function global:Invoke-WebRequest {
			[CmdletBinding()]
			param([string]$Uri, [string]$OutFile, [hashtable]$Headers, [int]$TimeoutSec, [switch]$UseBasicParsing)
			$global:TlcTestDownloadCalls++
			Copy-Item -LiteralPath $sourcePath -Destination $OutFile -Force
			return [pscustomobject]@{ StatusCode = 200; Content = '' }
		}

		Invoke-TlcWebRequest -Uri 'https://example.invalid/tool.bin' -OutFile $destination -ExpectedSha256 $expected -MaxRetries 1 | Out-Null
		Assert-True ($global:TlcTestDownloadCalls -eq 1) 'Verified download did not invoke the transport exactly once.'
		Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant() -eq $expected) 'Verified download produced the wrong output.'
		Invoke-TlcWebRequest -Uri 'https://example.invalid/tool.bin' -OutFile $destination -ExpectedSha256 $expected -MaxRetries 1 | Out-Null
		Assert-True ($global:TlcTestDownloadCalls -eq 1) 'A verified cache entry was not reused.'

		$cacheFile = Get-TlcCachePathForUri -Uri 'https://example.invalid/tool.bin' -Extension 'bin'
		[IO.File]::WriteAllText($cacheFile, 'corrupt cache')
		Invoke-TlcWebRequest -Uri 'https://example.invalid/tool.bin' -OutFile $destination -ExpectedSha256 $expected -MaxRetries 1 | Out-Null
		Assert-True ($global:TlcTestDownloadCalls -eq 2) 'A corrupt cache entry was reused instead of being redownloaded.'

		[IO.File]::WriteAllText($sourcePath, 'malicious replacement')
		$failedClosed = $false
		try { Invoke-TlcWebRequest -Uri 'https://example.invalid/other.bin' -OutFile $destination -ExpectedSha256 $expected -MaxRetries 1 | Out-Null } catch { $failedClosed = $true }
		Assert-True $failedClosed 'A SHA-256 mismatch did not fail the download.'
		Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant() -eq $expected) 'A failed download replaced the previously verified destination.'

		$unverifiedRejected = $false
		try { Invoke-TlcWebRequest -Uri 'https://example.invalid/unverified.bin' -OutFile $destination -MaxRetries 1 | Out-Null } catch { $unverifiedRejected = $true }
		Assert-True $unverifiedRejected 'Strict download policy accepted an artifact without an independent checksum or signature.'
		Assert-True ($global:TlcTestDownloadCalls -eq 3) 'Strict download policy invoked the transport before rejecting an unverified artifact.'

		$env:TLC_REQUIRE_VERIFIED_DOWNLOADS = $null
		Invoke-TlcWebRequest -Uri 'https://example.invalid/tofu.bin' -OutFile $destination -MaxRetries 1 | Out-Null
		Invoke-TlcWebRequest -Uri 'https://example.invalid/tofu.bin' -OutFile $destination -MaxRetries 1 | Out-Null
		Assert-True ($global:TlcTestDownloadCalls -eq 5) 'An unverified trust-on-first-use download was cached or reused.'
		$tofuCache = Get-TlcCachePathForUri -Uri 'https://example.invalid/tofu.bin' -Extension 'bin'
		Assert-True (-not (Test-Path -LiteralPath $tofuCache)) 'An unverified trust-on-first-use cache entry was persisted.'
	} finally {
		Remove-Item Function:\global:Invoke-WebRequest -Force -ErrorAction SilentlyContinue
		Remove-Variable TlcTestDownloadCalls -Scope Global -Force -ErrorAction SilentlyContinue
		$env:TLC_CACHE_ROOT = $oldCacheRoot
		$env:TLC_REQUIRE_VERIFIED_DOWNLOADS = $oldRequireVerified
		Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	Write-Host 'Validated atomic, integrity-checked download and cache behavior.'
}

function Test-PackageLifecycleStateTransitions {
	. .\src\main.ps1

	$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("toolchains-lifecycle-test-" + [Guid]::NewGuid().ToString('n'))
	$oldPkgRoot = $env:TLC_PKG_ROOT
	$oldPrefix = $env:npm_config_prefix
	$global:TlcTestNpmInstalls = @()
	try {
		$env:TLC_PKG_ROOT = $tempRoot
		New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

		function global:npm {
			param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Remaining)
			$global:LASTEXITCODE = 0
			$tokens = @($Remaining | ForEach-Object { [string]$_ })
			if ($tokens.Count -ge 3 -and $tokens[0] -eq 'view' -and $tokens[2] -eq 'version') {
				if ($tokens[1] -eq 'pnpm') { return '10.12.3' }
				if ($tokens[1] -eq 'yarn') { return '1.22.22' }
			}
			if ($tokens.Count -ge 3 -and $tokens[0] -eq 'install' -and $tokens[1] -eq '-g') {
				$global:TlcTestNpmInstalls += $tokens[2]
				return
			}
			throw "unexpected npm invocation: $($tokens -join ' ')"
		}

		foreach ($case in @(
			@{ Path = '.\src\pkgs\pnpm.ps1'; Name = 'pnpm'; Version = '10.12.3' },
			@{ Path = '.\src\pkgs\yarn\yarn.ps1'; Name = 'yarn'; Version = '1.22.22' }
		)) {
			Clear-TlcPackageScript
			& $case.Path
			$TlcPackageConfig.Latest = [TlcSemanticVersion]::new()
			Install-TlcPackage
			Assert-True (-not $TlcPackageConfig.UpToDate) "$($case.Name) marked a newly installed upstream version up-to-date and would suppress tests/publication."
			Assert-True ($TlcPackageConfig.Version -eq $case.Version) "$($case.Name) did not record the discovered upstream version."
			Assert-True ($global:TlcTestNpmInstalls -contains "$($case.Name)@$($case.Version)") "$($case.Name) did not install the exact discovered version."

			$installCount = $global:TlcTestNpmInstalls.Count
			Clear-TlcPackageScript
			& $case.Path
			$TlcPackageConfig.Latest = [TlcSemanticVersion]::new($case.Version)
			Install-TlcPackage
			Assert-True $TlcPackageConfig.UpToDate "$($case.Name) did not recognize an already-published version."
			Assert-True ($global:TlcTestNpmInstalls.Count -eq $installCount) "$($case.Name) reinstalled an already-published version."
		}

		Clear-TlcPackageScript
		. .\src\pkgs\notepadplus.ps1
		function Get-DockerTags { return @{ tags = @('notepadpp-8.8.3') } }
		Invoke-TlcInit
		Assert-True ($TlcPackageConfig.Latest.ToString() -eq '8.8.3') 'Notepad++ lifecycle could not discover its published tag.'
	} finally {
		Clear-TlcPackageScript
		Remove-Item Function:\global:npm -Force -ErrorAction SilentlyContinue
		Remove-Variable TlcTestNpmInstalls -Scope Global -Force -ErrorAction SilentlyContinue
		$env:TLC_PKG_ROOT = $oldPkgRoot
		$env:npm_config_prefix = $oldPrefix
		Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	Write-Host 'Validated package lifecycle state transitions.'
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
		$dockerIgnore = @(Get-Content -LiteralPath (Join-Path $tempRoot '.dockerignore'))
		Assert-True ($dockerfile -match 'COPY "official-models\.manifest\.json" "/official-models\.manifest\.json"') 'Layered Dockerfile does not copy the model manifest.'
		Assert-True ($dockerfile -match 'cache/hf-cache/models--Example--Tiny/blobs/abc123') 'Layered Dockerfile does not copy individual model blobs.'
		Assert-True ($dockerfile -match 'cache/hf-cache/models--Example--Tiny/snapshots') 'Layered Dockerfile does not copy model snapshots.'
		Assert-True ($dockerIgnore -contains '_stage') 'Layered model .dockerignore does not exclude staging content.'

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
& .\scripts\test-package-spec.ps1
Test-HuggingFaceHelpers
Test-HuggingFaceLayeredDockerfile
Test-WorkflowRunnerDefaults
Test-ProductionReadinessPolicies
Test-AtomicVerifiedDownloads
Test-PackageLifecycleStateTransitions
