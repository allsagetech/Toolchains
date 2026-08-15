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

function Test-WebRequestUserAgent {
	. .\src\main.ps1

	$oldUserAgent = $env:TLC_USER_AGENT
	try {
		Remove-Item Env:TLC_USER_AGENT -ErrorAction SilentlyContinue
		$defaultHeaders = Get-TlcRequestHeaders
		Assert-True ([string]$defaultHeaders['User-Agent'] -match '^Mozilla/5\.0 .+ Chrome/[0-9]+') 'Default web requests do not use the browser-compatible User-Agent.'

		$customHeaders = Get-TlcRequestHeaders -Headers @{ 'User-Agent' = 'custom-agent/1.0'; 'Accept' = 'application/json' }
		Assert-True ([string]$customHeaders['User-Agent'] -eq 'custom-agent/1.0') 'A caller-supplied User-Agent was overwritten.'
		Assert-True ([string]$customHeaders['Accept'] -eq 'application/json') 'Caller-supplied request headers were not preserved.'

		$env:TLC_USER_AGENT = 'environment-agent/2.0'
		$environmentHeaders = Get-TlcRequestHeaders
		Assert-True ([string]$environmentHeaders['User-Agent'] -eq 'environment-agent/2.0') 'TLC_USER_AGENT did not override the default User-Agent.'
	} finally {
		$env:TLC_USER_AGENT = $oldUserAgent
	}

	$networkText = Get-Content -LiteralPath .\src\network.ps1 -Raw
	Assert-True ($networkText -match 'registry-1\.docker\.io/v2/\$repositoryPath/tags/list') 'Toolchain tag discovery does not use the Docker Registry V2 tag-list route.'
	Assert-True ($networkText -notmatch 'hub\.docker\.com/v2/repositories') 'Toolchain tag discovery still uses the legacy Docker Hub repository route.'

	$directPackageRequests = @(Get-ChildItem -Path .\src\pkgs -Filter '*.ps1' -Recurse -File | Where-Object {
		(Get-Content -LiteralPath $_.FullName -Raw) -match '\bInvoke-(?:RestMethod|WebRequest)\b'
	})
	Assert-True ($directPackageRequests.Count -eq 0) "Package scripts bypass the shared HTTP helpers: $($directPackageRequests.FullName -join ', ')"
	Write-Host 'Validated browser-compatible request headers and Docker Registry V2 endpoints.'
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

function Test-ModelCategoryMarkers {
	. .\src\main.ps1

	$configs = @()
	try {
		foreach ($package in Get-ChildItem -Path .\src\pkgs -Filter '*.ps1' -Recurse -File | Sort-Object FullName) {
			Clear-TlcPackageScript
			& $package.FullName
			Test-TlcPackageScript
			$configs += ,[pscustomobject]@{
				Name = [string]$TlcPackageConfig.Name
				Tier = if ($TlcPackageConfig.Tier) { [string]$TlcPackageConfig.Tier } else { 'tooling' }
			}
		}
	} finally {
		Clear-TlcPackageScript
	}

	$modelPackages = @(Get-TlcModelCategoryPackages -PackageConfigs $configs)
	$expectedPackages = @(
		'openai-gpt-oss-20b',
		'qwen2.5-0.5b-instruct',
		'qwen2.5-coder-7b-instruct',
		'qwen3-0.6b',
		'smollm2-135m-instruct',
		'smollm2-360m-instruct'
	)
	Assert-True ($modelPackages.Count -eq $expectedPackages.Count) "Expected $($expectedPackages.Count) model packages, got $($modelPackages.Count)."
	Assert-True ((@($modelPackages.Package) -join ',') -eq ($expectedPackages -join ',')) 'Model category packages do not match explicit model tiers.'
	foreach ($modelPackage in $modelPackages) {
		Assert-True ($modelPackage.Tier -in @('model-small', 'model-large')) "Unexpected model package tier: $($modelPackage.Tier)"
	}
	Assert-True (-not (@($modelPackages.Package) -contains 'codex')) 'Tooling package codex was inferred to be a model by name.'
	Assert-True (-not (@($modelPackages.Package) -contains 'lmstudio')) 'Tooling package lmstudio was inferred to be a model by name.'

	$unsafeRejected = $false
	try {
		Get-TlcModelCategoryPackages -PackageConfigs @(@{ Name = 'bad--name'; Tier = 'model-small' }) | Out-Null
	} catch {
		$unsafeRejected = $true
	}
	Assert-True $unsafeRejected 'Package names containing the reserved category-marker separator were accepted.'
	$leadingUnderscoreRejected = $false
	try {
		Get-TlcModelCategoryPackages -PackageConfigs @(@{ Name = '_hidden-model'; Tier = 'model-small' }) | Out-Null
	} catch {
		$leadingUnderscoreRejected = $true
	}
	Assert-True $leadingUnderscoreRejected 'Package name grammar is broader than the Toolchain marker parser.'

	$deduplicated = @(Get-TlcModelCategoryPackages -PackageConfigs @(
		@{ Name = 'same-model'; Tier = 'model-small' },
		@{ Name = 'same-model'; Tier = 'model-small' }
	))
	Assert-True ($deduplicated.Count -eq 1) 'Duplicate identical model descriptors were not deduplicated.'

	$generationTags = @(
		'tlc-kind-model-v1-4-2--model-a',
		'tlc-kind-model-v1-4-2--model-b',
		'tlc-kind-model-v1-5-2--model-a',
		'tlc-kind-model-v1-6-2--model-a',
		'tlc-kind-model-v1-6-3--model-b',
		'tlc-kind-model--legacy-model',
		'ordinary-tool-9.0.0'
	)
	$generations = @(Get-TlcModelCategoryGenerations -RegistryTags $generationTags)
	$generation4 = @($generations | Where-Object Generation -eq 4)
	$generation5 = @($generations | Where-Object Generation -eq 5)
	$generation6 = @($generations | Where-Object Generation -eq 6)
	Assert-True ($generation4.Count -eq 1 -and $generation4[0].Complete) 'A complete model marker generation was rejected.'
	Assert-True ($generation5.Count -eq 1 -and -not $generation5[0].Complete) 'A partially propagated generation was accepted.'
	Assert-True ($generation6.Count -eq 1 -and -not $generation6[0].Complete) 'A conflicting-count generation was accepted.'

	$noOpPlan = Get-TlcModelCategoryPublicationPlan -DesiredPackages @('model-b', 'model-a') -RegistryTags @(
		'tlc-kind-model-v1-4-2--model-a',
		'tlc-kind-model-v1-4-2--model-b'
	)
	Assert-True (-not $noOpPlan.NeedsPublication -and $noOpPlan.Generation -eq 4) 'Highest observed complete matching generation was not treated as a no-op.'
	$supersedingPlan = Get-TlcModelCategoryPublicationPlan -DesiredPackages @('model-b', 'model-a') -RegistryTags $generationTags
	Assert-True ($supersedingPlan.NeedsPublication -and $supersedingPlan.Generation -eq 7) 'A newer incomplete/conflicting generation was not superseded despite matching older complete state.'
	$newPlan = Get-TlcModelCategoryPublicationPlan -DesiredPackages @('model-a', 'model-c') -RegistryTags $generationTags
	Assert-True ($newPlan.NeedsPublication -and $newPlan.Generation -eq 7) 'New publication did not advance beyond every observed generation.'
	Assert-True ((@($newPlan.MarkerTags) -join ',') -eq 'tlc-kind-model-v1-7-2--model-a,tlc-kind-model-v1-7-2--model-c') 'New generation marker tags are not canonical.'
	$emptyPlan = Get-TlcModelCategoryPublicationPlan -DesiredPackages @() -RegistryTags $generationTags
	Assert-True ((@($emptyPlan.MarkerTags) -join ',') -eq 'tlc-kind-model-v1-7-0--empty') 'Empty model set did not produce the count-zero sentinel.'

	$normalized = @(Get-TlcModelCategoryGenerations -RegistryTags @(
		'tlc-kind-model-v1-0008-02--model-a',
		'tlc-kind-model-v1-8-2--model-b'
	))
	Assert-True ($normalized.Count -eq 1 -and $normalized[0].Generation -eq 8 -and $normalized[0].Complete) 'Equivalent UInt64/count spellings were not normalized into one complete generation.'
	$caseConflict = @(Get-TlcModelCategoryGenerations -RegistryTags @(
		'tlc-kind-model-v1-9-2--model-a',
		'tlc-kind-model-v1-9-2--MODEL-A'
	))
	Assert-True ($caseConflict.Count -eq 1 -and -not $caseConflict[0].Complete) 'Case-conflicting package spellings formed a complete generation.'
	Assert-True ($null -eq (ConvertFrom-TlcModelCategoryMarkerTag -Tag 'tlc-kind-model-v1-9-0--model-a')) 'A non-sentinel count-zero marker was accepted.'
	Assert-True ($null -eq (ConvertFrom-TlcModelCategoryMarkerTag -Tag 'tlc-kind-model-v1-9-10001--model-a')) 'A marker count above the client limit was accepted.'

	$planPath = Join-Path ([IO.Path]::GetTempPath()) "toolchains-model-plan-$([Guid]::NewGuid().ToString('n')).json"
	try {
		& .\scripts\export-model-category-marker-plan.ps1 -OutputPath $planPath -Repository 'allsagetech/toolchains'
		$planDocument = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
		Assert-True ([int]$planDocument.schemaVersion -eq 1) 'Exported model marker plan has an unexpected schema version.'
		Assert-True ((@($planDocument.desiredPackages) -join ',') -eq ($expectedPackages -join ',')) 'Exported model marker plan does not contain the tier-derived package set.'
	} finally {
		Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
	}

	$publisherText = Get-Content -LiteralPath .\scripts\publish-model-category-markers.ps1 -Raw
	$exporterText = Get-Content -LiteralPath .\scripts\export-model-category-marker-plan.ps1 -Raw
	Assert-True ($publisherText -match "'buildx', 'imagetools', 'create'") 'Model marker publisher does not use docker buildx imagetools create.'
	Assert-True ($publisherText -match "'--prefer-index=false'") 'Model marker publisher may wrap a source manifest instead of preserving its digest.'
	Assert-True ($publisherText -match 'registry-1\.docker\.io/v2/\$repositoryPath/tags/list') 'Publisher does not use the Docker Registry V2 tag-list route.'
	Assert-True ($publisherText -notmatch '(?i)\bDELETE\b|/manifests/') 'Publisher contains a destructive tag or manifest deletion path.'
	Assert-True ($publisherText -notmatch 'src[/\\]main\.ps1|src[/\\]pkgs') 'Privileged publisher can execute package descriptors.'
	Assert-True ($exporterText -match 'src[/\\]main\.ps1' -and $exporterText -match 'src[/\\]pkgs') 'Unprivileged plan exporter does not derive names from validated descriptors.'
	Assert-True ($exporterText -match 'desiredPackages' -and $exporterText -notmatch 'SourceTag|digest') 'Plan artifact includes registry state instead of names only.'

	# Dot-source only the helper definitions; executable publication is guarded.
	. .\scripts\publish-model-category-markers.ps1
	$staleDigest = 'sha256:' + ('a' * 64)
	$expectedDigest = 'sha256:' + ('b' * 64)
	$descriptorQueue = [Collections.Generic.Queue[object]]::new()
	$descriptorQueue.Enqueue([pscustomobject]@{ Digest = $staleDigest })
	$descriptorQueue.Enqueue([pscustomobject]@{ Digest = $expectedDigest })
	$observedDescriptor = Wait-TlcRemoteManifestDigest -Reference 'repo:marker' -ExpectedDigest $expectedDigest -Attempts 3 `
		-DescriptorReader { param($Reference) $descriptorQueue.Dequeue() } -SleepAction { param($Seconds) }
	Assert-True ($observedDescriptor.Digest -eq $expectedDigest -and $descriptorQueue.Count -eq 0) 'Digest polling accepted stale-but-valid marker content.'

	$snapshotQueue = [Collections.Generic.Queue[object]]::new()
	$snapshotQueue.Enqueue([string[]]@('tag-a'))
	$snapshotQueue.Enqueue([string[]]@('tag-a', 'tag-b'))
	$snapshotQueue.Enqueue([string[]]@('tag-b', 'tag-a'))
	$stableTags = @(Get-TlcStableDockerHubTags -RepositoryName 'owner/repo' -Attempts 3 `
		-TagReader { param($Repo) @($snapshotQueue.Dequeue()) } -SleepAction { param($Seconds) })
	Assert-True (($stableTags -join ',') -eq 'tag-a,tag-b' -and $snapshotQueue.Count -eq 0) 'Registry snapshot retry did not require two identical normalized listings.'

	$propagationQueue = [Collections.Generic.Queue[object]]::new()
	$propagationQueue.Enqueue([string[]]@('tlc-kind-model-v1-10-2--model-a'))
	$propagationQueue.Enqueue([string[]]@('tlc-kind-model-v1-10-2--model-a', 'tlc-kind-model-v1-10-2--model-b'))
	$completeState = Wait-TlcCompleteModelCategoryGeneration -RepositoryName 'owner/repo' -Generation 10 -DesiredPackages @('model-a', 'model-b') -Attempts 2 `
		-TagReader { param($Repo) @($propagationQueue.Dequeue()) } -SleepAction { param($Seconds) }
	Assert-True ($completeState.Complete -and $propagationQueue.Count -eq 0) 'Generation polling accepted incomplete propagation.'

	$buildxCalls = [Collections.Generic.List[object]]::new()
	$digestWaitCalls = [Collections.Generic.List[object]]::new()
	$generationWaitCalls = [Collections.Generic.List[object]]::new()
	$publishPlan = [pscustomobject]@{
		Generation      = [UInt64]11
		DesiredPackages = @('model-a')
		MarkerTags      = @('tlc-kind-model-v1-11-1--model-a')
	}
	Publish-TlcModelCategoryGeneration -RepositoryName 'owner/repo' -PublicationPlan $publishPlan `
		-Anchor ([pscustomobject]@{ Digest = $expectedDigest }) `
		-BuildxInvoker { param([string[]]$CommandArguments) $buildxCalls.Add([string[]]@($CommandArguments)) } `
		-DigestWaiter { param($MarkerReference, $Digest) $digestWaitCalls.Add([pscustomobject]@{ Reference = $MarkerReference; Digest = $Digest }) } `
		-GenerationWaiter { param($Repo, $GenerationNumber, [string[]]$Packages) $generationWaitCalls.Add([pscustomobject]@{ Repository = $Repo; Generation = $GenerationNumber; Packages = @($Packages) }) }
	$expectedArguments = @(
		'buildx', 'imagetools', 'create', '--prefer-index=false', '--tag',
		'owner/repo:tlc-kind-model-v1-11-1--model-a',
		"owner/repo@$expectedDigest"
	)
	Assert-True ($buildxCalls.Count -eq 1 -and ((@($buildxCalls[0]) -join '|') -ceq ($expectedArguments -join '|'))) 'Marker publication did not use the exact digest-qualified imagetools argv.'
	Assert-True ($digestWaitCalls.Count -eq 1 -and $digestWaitCalls[0].Reference -ceq 'owner/repo:tlc-kind-model-v1-11-1--model-a' -and $digestWaitCalls[0].Digest -ceq $expectedDigest) 'Published marker digest was not verified exactly.'
	Assert-True ($generationWaitCalls.Count -eq 1 -and $generationWaitCalls[0].Generation -eq 11) 'Complete-generation readback was not requested after marker publication.'

	$workflowText = Get-Content -LiteralPath .\.github\workflows\build-push.yml -Raw
	Assert-True ($workflowText -match '(?m)^  model-category-marker-plan:') 'Release workflow does not define the unprivileged model marker plan job.'
	Assert-True ($workflowText -match '(?m)^  model-category-markers:') 'Release workflow does not define the model category marker job.'
	$planJobText = [regex]::Match($workflowText, '(?ms)^  model-category-marker-plan:.*?(?=^  model-category-markers:)').Value
	$publisherJobText = [regex]::Match($workflowText, '(?ms)^  model-category-markers:.*\z').Value
	Assert-True ($planJobText -match 'export-model-category-marker-plan\.ps1' -and $planJobText -match 'upload-artifact@') 'Plan job does not export and upload its names-only artifact.'
	Assert-True ($planJobText -notmatch 'DOCKERHUB_|login-action@|environment:\s*package-release') 'Unprivileged plan job is exposed to release credentials.'
	Assert-True ($planJobText -match "github\.ref == 'refs/heads/main'") 'Authoritative marker planning is not limited to main.'
	Assert-True ($planJobText -match "\(needs\.release\.result == 'success' \|\| needs\.release\.result == 'skipped'\)") 'Marker planning can bypass release success/no-op gating.'
	Assert-True ($publisherJobText -match 'download-artifact@' -and $publisherJobText -match 'login-action@' -and $publisherJobText -match 'publish-model-category-markers\.ps1') 'Privileged publisher job is missing its isolated artifact/login/publication sequence.'
	Assert-True ($publisherJobText -match 'group: toolchains-model-category-markers-\$\{\{ github\.repository \}\}') 'Publisher lacks repository-wide marker concurrency.'
	Assert-True ($publisherJobText -notmatch 'export-model-category-marker-plan\.ps1|src[/\\]pkgs') 'Privileged publisher job can regenerate descriptor state.'

	Write-Host "Validated $($modelPackages.Count) explicit model packages and generational marker publication."
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
	$workflowText = Get-Content -LiteralPath .\.github\workflows\build-push.yml -Raw
	$workflowRef = [regex]::Match($workflowText, '(?m)^\s*TOOLCHAIN_REF:\s*([0-9a-f]{40})\s*$')
	Assert-True $workflowRef.Success 'Package workflow does not pin Toolchain to an immutable commit.'
	Assert-True ($installerText -match [regex]::Escape($workflowRef.Groups[1].Value)) 'Toolchain installer default does not match the workflow immutable commit.'
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
	$dockerDesktopPackageText = Get-Content -LiteralPath .\src\pkgs\docker-desktop.ps1 -Raw
	$dockerDesktopInstallerText = Get-Content -LiteralPath .\src\assets\docker-desktop\docker-desktop-install.ps1 -Raw
	Assert-True ($dockerDesktopPackageText -match 'Get-TlcDockerDesktopRelease') 'Docker Desktop package does not use the official appcast metadata parser.'
	Assert-True ($dockerDesktopInstallerText -match 'Get-FileHash.+SHA256') 'Docker Desktop bootstrap does not verify the installer SHA-256.'
	Assert-True ($dockerDesktopInstallerText -match 'Get-AuthenticodeSignature') 'Docker Desktop bootstrap does not verify the installer Authenticode signature.'
	Assert-True ($dockerDesktopInstallerText -match "arguments \+= '--user'") 'Docker Desktop bootstrap does not default to a per-user installation.'
	Assert-True ($dockerDesktopInstallerText -notmatch "arguments = @\('install',\s*'--accept-license'") 'Docker Desktop bootstrap accepts the license without explicit user consent.'
	$podmanPackageText = Get-Content -LiteralPath .\src\pkgs\podman.ps1 -Raw
	Assert-True ($podmanPackageText -match "Owner 'podman-container-tools'") 'Podman package does not use the official release repository.'
	Assert-True ($podmanPackageText -match 'podman-remote-release-windows_amd64\\\.zip') 'Podman package does not select the official Windows x64 CLI bundle.'
	Assert-True ($podmanPackageText -match 'Invoke-TlcVerifiedGoCommandBuild') 'Podman does not use the shared checksum-verified source build.'
	Assert-True ($podmanPackageText -match "GoToolchain = 'go1\.26\.6'") 'Podman does not use the patched Go toolchain.'
	Assert-True ($podmanPackageText -match "PatchedCryptoVersion = 'v0\.52\.0'") 'Podman machine helpers do not require the fixed x/crypto version.'
	Assert-True ($podmanPackageText -match "GvproxyVersion = 'v0\.8\.9'") 'Podman does not pin the upstream machine helper source version.'
	Assert-True ($podmanPackageText -match 'BuildRevision = 1') 'Patched Podman build does not carry a republishable package revision.'
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
	Clear-TlcPackageScript
	. .\src\pkgs\node\node24.ps1
	$node24Publication = Get-TlcPackagePublicationState
	Assert-True $node24Publication.VerifiedDownloads 'Node 24 security quarantine incorrectly marks its verified upstream archive unverified.'
	Assert-True (-not $node24Publication.PublishEligible) 'Node 24 can publish despite active HIGH/CRITICAL findings in its upstream npm bundle.'
	Assert-True (-not [string]::IsNullOrWhiteSpace($node24Publication.QuarantineReason)) 'Node 24 security quarantine has no explanation.'
	$sevenZipPackageText = Get-Content -LiteralPath .\src\pkgs\7-zip.ps1 -Raw
	Assert-True ($sevenZipPackageText -match 'github\.com/ip7z/7zip/releases/download/25\.01/7z2501-x64\.exe') '7-Zip does not use the official GitHub release asset with published SHA-256 metadata.'
	$doxygenPackageText = Get-Content -LiteralPath .\src\pkgs\doxygen.ps1 -Raw
	Assert-True ($doxygenPackageText -match 'github\.com/doxygen/doxygen/releases/download/\$Tag/\$AssetName') 'Doxygen does not use its official GitHub release asset with published SHA-256 metadata.'
	$vsBuildToolsText = Get-Content -LiteralPath .\src\pkgs\vs-buildtools.ps1 -Raw
	Assert-True ($vsBuildToolsText.Contains('${env:ProgramFiles(x86)}\Microsoft SDKs')) 'Visual Studio Build Tools omits an SDK directory referenced by its generated PATH contract.'
	Assert-True ($vsBuildToolsText -match 'ConvertTo-TlcCanonicalPathList\s+-Value\s+\$value\s+-ContainedRoot') 'Visual Studio Build Tools does not canonicalize generated path-list variables before writing its package contract.'
	if (Test-TlcHostIsWindows) {
		$canonicalPathList = ConvertTo-TlcCanonicalPathList -Value 'D:\pkg\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\vsdevcmd\core\..\..\..\..\..\..\..\Windows Kits\10\bin\10.0.26100.0\\x64;C:\Windows\System32' -ContainedRoot 'D:\pkg'
		Assert-True ($canonicalPathList -eq 'D:\pkg\Windows Kits\10\bin\10.0.26100.0\x64;C:\Windows\System32') 'Path-list canonicalization did not normalize the Visual Studio SDK path emitted by VsDevCmd.'
		foreach ($unsafePath in @('D:\pkg\..\outside', 'D:/pkg/../outside', '..\outside', 'bin\..\..\outside')) {
			$pathEscapeRejected = $false
			try { ConvertTo-TlcCanonicalPathList -Value $unsafePath -ContainedRoot 'D:\pkg' | Out-Null } catch { $pathEscapeRejected = $true }
			Assert-True $pathEscapeRejected "Path-list canonicalization accepted unsafe entry: $unsafePath"
		}
	}
	$utilText = Get-Content -LiteralPath .\src\util.ps1 -Raw
	Assert-True ($utilText -match '\$assetName\.sha256\.txt') 'GitHub release verification does not discover publisher companion SHA-256 assets.'
	Assert-True ($utilText -match '/releases/latest') 'GitHub release discovery does not prefer the bounded latest-release endpoint.'
	Assert-True ($utilText -match 'releases\?per_page=20') 'GitHub release fallback still requests oversized release-history pages.'
	Assert-True ($utilText -match "OSPlatform\]::Windows\)\) \{ 'Path' \} else \{ 'PATH' \}") 'Local execution does not normalize PATH casing for Linux hosts.'
	$releaseSelection = Select-TlcGitHubReleaseAsset -Releases @(
		[pscustomobject]@{ tag_name = 'v2.0.0'; prerelease = $false; assets = @() },
		[pscustomobject]@{ tag_name = 'v1.9.0'; prerelease = $false; assets = @([pscustomobject]@{ name = 'tool-win-x64.zip'; browser_download_url = 'https://example.invalid/tool.zip' }) }
	) -AssetPattern '^tool-win-x64\.zip$' -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
	Assert-True ([string]$releaseSelection.Release.tag_name -eq 'v1.9.0') 'GitHub release selection did not fall back when the newest release had no matching asset.'
	$directPushSelection = @(Get-TlcPushPackagePaths -ChangedPath @('src/pkgs/podman.ps1', 'src/pkgs/podman.ps1', 'README.md'))
	Assert-True ($directPushSelection.Count -eq 1 -and $directPushSelection[0] -eq 'src/pkgs/podman.ps1') 'Push routing did not select exactly one directly changed package.'
	$assetPushSelection = @(Get-TlcPushPackagePaths -ChangedPath @('src/assets/kubectl/main.go'))
	Assert-True ($assetPushSelection.Count -eq 2) 'Push routing did not select both kubectl platform packages for their shared source asset.'
	Assert-True ($assetPushSelection -contains 'src/pkgs/kubectl.ps1') 'Push routing omitted the Windows kubectl package for its shared source asset.'
	Assert-True ($assetPushSelection -contains 'src/pkgs/kubectl-linux.ps1') 'Push routing omitted the Linux kubectl package for its shared source asset.'
	$sharedPushSelection = @(Get-TlcPushPackagePaths -ChangedPath @('src/main.ps1'))
	Assert-True ($sharedPushSelection.Count -eq 2) 'Shared publication infrastructure changes do not select a bounded Windows/Linux smoke set.'
	Assert-True ($sharedPushSelection -contains 'src/pkgs/websocat.ps1') 'Shared publication infrastructure changes omit the Windows smoke package.'
	Assert-True ($sharedPushSelection -contains 'src/pkgs/git-linux.ps1') 'Shared publication infrastructure changes omit the Linux smoke package.'
	$familyPushSelection = @(Get-TlcPushPackagePaths -ChangedPath @('src/package-families.ps1'))
	foreach ($familyRepresentative in @('src/pkgs/node/node22.ps1', 'src/pkgs/jdk/jdk17.ps1', 'src/pkgs/kubectl.ps1', 'src/pkgs/kubectl-linux.ps1')) {
		Assert-True ($familyPushSelection -contains $familyRepresentative) "Shared package-family changes omit representative $familyRepresentative."
	}
	Assert-True (@(Get-TlcPushPackagePaths -ChangedPath @('README.md', 'CHANGELOG.md')).Count -eq 0) 'Documentation-only pushes still select publication jobs.'
	$workflowText = Get-Content -LiteralPath .\.github\workflows\build-push.yml -Raw
	Assert-True ($workflowText -match '\$TlcPackageConfig\.Tags\s*=\s*@\(\)') 'Forced PR smoke builds do not clear published package tags.'
	Assert-True ($workflowText -match 'Where-Object \{ \[bool\]\$_\.verified_downloads -and \[bool\]\$_\.publish_eligible \}') 'Workflow matrices do not exclude unverified or quarantined packages.'
	Assert-True ($workflowText -match 'Get-TlcPushPackagePaths -ChangedPath \$changed') 'Push workflows do not route the changed file set into the bounded package selector.'
	Assert-True ($workflowText -match 'git diff --name-only \$before \$after') 'Push workflows do not compare the exact before/after commit trees.'
	Assert-True ($workflowText -match 'full_inventory:[\s\S]+default:\s+false') 'Manual workflows do not require an explicit full-inventory opt-in.'
	Assert-True ($workflowText -match "Manual runs require a package selector unless 'full_inventory' is explicitly enabled") 'Manual workflows do not fail closed when neither a package nor a full inventory is selected.'
	Assert-True ($workflowText -match 'Scheduled runs remain the automatic complete inventory sweep\.[\s\S]+Save-WorkflowMatrix') 'Scheduled workflows no longer perform the full package inventory sweep.'
	Assert-True ($workflowText -match 'Where-Object \{ \[string\]\$_\.tier -ne ''model-large'' \}') 'Large-model publication jobs are not disabled before matrix export.'
	Assert-True ($workflowText -notmatch '\(\$tier -eq ''model-large'' -and') 'Large-model jobs can still enter the protected release matrix.'
	Assert-True ($workflowText -notmatch "toolchains-large") 'Release workflow still queues work on the disabled large-model runner.'
	Assert-True ($workflowText -match 'release:[\s\S]+max-parallel:\s+8') 'Release publication does not preserve runner capacity with bounded parallelism.'
	Assert-True ($workflowText -match 'function Invoke-CosignVerification') 'Cosign verification has no bounded retry wrapper.'
	Assert-True ($workflowText -match "@\('--offline', '--timeout', '30s'") 'Cosign verification does not use the signed transparency bundle with a bounded internal timeout.'
	Assert-True ($workflowText -match 'Verify signature and attestations fail closed[\s\S]+timeout-minutes:\s+6') 'Cosign verification step has no GitHub-enforced deadline.'
	Assert-True ($workflowText -match 'Redirected Process streams can keep a[\s\S]+Windows child attached indefinitely') 'Cosign verification does not document why child-process output must remain inherited.'
	Assert-True ($workflowText -notmatch 'RedirectStandardOutput|RedirectStandardError|-RedirectStandardOutput|-RedirectStandardError') 'Cosign verification still redirects child-process output and can deadlock the Windows runner.'
	Assert-True ($workflowText -notmatch 'ReadToEndAsync|GetAwaiter\(\)\.GetResult\(\)') 'Cosign verification can still hang while draining a terminated child process.'
	Assert-True ($workflowText -match '\$process\.WaitForExit\(\$TimeoutSeconds \* 1000\)') 'Cosign verification has no external hard timeout.'
	Assert-True ($workflowText -match '\$process\.Kill\(\)' -and $workflowText -match '\$process\.WaitForExit\(5000\)') 'Cosign verification does not terminate and reap a timed-out process.'
	Assert-True ($workflowText -notmatch '\$process\.Kill\(\$true\)') 'Cosign verification still uses blocking process-tree enumeration on timeout.'
	Assert-True (([regex]::Matches($workflowText, 'GH_TOKEN:\s+\$\{\{ github\.token \}\}')).Count -ge 4) 'Parallel build jobs do not authenticate GitHub API requests.'
	Assert-True ($workflowText -match 'RUNNER_OS -eq ''Linux''[\s\S]+Get-ChildItem -LiteralPath \$full -Force \| Remove-Item') 'Linux package cleanup still removes the protected mount root.'
	Assert-True ($workflowText -match 'scanner-smoke:') 'Publication does not validate scanner bootstrap before starting the package matrix.'
	Assert-True ($workflowText -match 'scanner-smoke:[\s\S]+needs: \[init, validate\][\s\S]+needs\.init\.outputs\.has-packages == ''true''') 'Scanner bootstrap runs when no package publication job was selected.'
	Assert-True ($workflowText -match 'Enforce supply-chain evidence gate') 'Publication does not distinguish scanner infrastructure failures from scan evidence.'
	Assert-True ($workflowText -match 'limit-severities-for-sarif:\s+true') 'Trivy SARIF evidence is not restricted to the enforced HIGH/CRITICAL severities.'
	Assert-True ($workflowText -match 'Install-VerifiedCosign\.ps1') 'Publication does not use the repository-controlled verified Cosign bootstrap.'
	Assert-True ($workflowText -notmatch 'sigstore/cosign-installer') 'Publication still depends on the broken Windows Cosign installer action.'
	$linuxDockerfileText = Get-Content -LiteralPath .\Dockerfile.linux -Raw
	Assert-True ($linuxDockerfileText -match '(?m)^FROM scratch\s*$') 'Ordinary Linux package images still inherit an unrelated operating-system filesystem.'
	Assert-True ($linuxDockerfileText -notmatch '(?m)^FROM (?:ubuntu|debian|alpine|mcr\.)') 'Ordinary Linux package images still inherit a vulnerable runtime base.'
	$localContractText = Get-Content -LiteralPath .\.github\scripts\Test-LocalImageContract.ps1 -Raw
	Assert-True ($localContractText -match 'docker create \$ImageRef ''toolchain-contract-placeholder''') 'Exact-image contract testing cannot inspect artifact-only scratch images.'
	Assert-True ($workflowText -match 'package-health-summary:') 'Publication does not produce a consolidated package-health artifact.'
	Assert-True ($workflowText -match 'Remove-DockerHubStagingTags\.ps1') 'Successful publication does not clean up its staging tag.'
	$stagingCleanupText = Get-Content -LiteralPath .\.github\scripts\Remove-DockerHubStagingTags.ps1 -Raw
	Assert-True ($stagingCleanupText -match 'https://hub\.docker\.com/v2/auth/token') 'Staging cleanup does not use the documented Docker Hub token endpoint.'
	Assert-True ($stagingCleanupText -match '/namespaces/\$namespaceSegment/repositories/\$repositorySegment/tags/\$tagSegment') 'Staging cleanup does not delete one exact Docker Hub tag.'
	Assert-True ($stagingCleanupText -notmatch '/manifests/') 'Staging cleanup can delete a shared registry manifest instead of one tag.'
	Assert-True ($stagingCleanupText -match "'User-Agent'") 'Docker Hub staging cleanup does not send an explicit browser User-Agent.'
	Assert-True ($stagingCleanupText -match 'IncludeOrphanedAttachments') 'Docker Hub cleanup cannot remove orphaned Cosign attachments.'
	Assert-True ($stagingCleanupText -match '\^sha256-\(\[0-9a-f\]\{64\}\)\\\.\(sig\|att\)\$') 'Docker Hub cleanup does not narrowly identify Cosign attachment tags.'
	Assert-True ($stagingCleanupText -match '\$durableDigests\.ContainsKey\(\$subjectDigest\)') 'Docker Hub cleanup can delete attachments that are referenced by final image tags.'
	Assert-True ($stagingCleanupText -match '\$freshStagingDigests\.ContainsKey\(\$subjectDigest\)') 'Docker Hub cleanup can delete attachments for an active staging image.'
	Assert-True ($stagingCleanupText -match 'AddMinutes\(-\$SafetyDelayMinutes\)') 'Docker Hub cleanup has no safety delay for in-flight publication.'
	Assert-True ($stagingCleanupText -match 'if \(\$DryRun\)') 'Docker Hub cleanup has no non-destructive preview mode.'
	Assert-True ($stagingCleanupText -match '\$pageResults\.Count -lt \$pageSize') 'Docker Hub cleanup trusts stale pagination metadata after bulk deletion.'
	Assert-True (Test-Path -LiteralPath .\.github\workflows\cleanup-staging-tags.yml -PathType Leaf) 'Orphaned staging tags have no scheduled cleanup workflow.'
	$stagingCleanupWorkflowText = Get-Content -LiteralPath .\.github\workflows\cleanup-staging-tags.yml -Raw
	Assert-True ($stagingCleanupWorkflowText -match 'environment:\s+package-release') 'Scheduled staging cleanup cannot access package-release environment secrets.'
	Assert-True ($stagingCleanupWorkflowText -match 'secrets\.DOCKERHUB_USERNAME' -and $stagingCleanupWorkflowText -match 'secrets\.DOCKERHUB_TOKEN') 'Scheduled staging cleanup does not receive the Docker Hub environment secrets.'
	Assert-True ($stagingCleanupWorkflowText -match 'include_orphaned_attachments:[\s\S]+default:\s+true') 'Scheduled cleanup does not include orphaned Cosign attachments.'
	Assert-True ($stagingCleanupWorkflowText -match 'dry_run:[\s\S]+default:\s+true') 'Manual Docker Hub cleanup is destructive by default.'
	Assert-True ($workflowText -match 'group:\s+toolchains-package-publication-' -and $stagingCleanupWorkflowText -match 'group:\s+toolchains-package-publication-refs/heads/main') 'Cleanup can race main package publication.'
	$cosignInstallerText = Get-Content -LiteralPath .\.github\scripts\Install-VerifiedCosign.ps1 -Raw
	Assert-True ($cosignInstallerText -match '\$version = ''v2\.6\.0''') 'Cosign bootstrap version is not pinned.'
	Assert-True ($cosignInstallerText -match '7beb4dd1e19a72c328bbf7c0d7342d744edbf5cbb082f227b2b76e04a21c16ef') 'Cosign Windows asset digest is not pinned.'
	Assert-True ($cosignInstallerText -match 'ea5c65f99425d6cfbb5c4b5de5dac035f14d09131c1a0ea7c7fc32eab39364f9') 'Cosign Linux asset digest is not pinned.'
	Assert-True ($cosignInstallerText -match "'User-Agent'") 'Cosign bootstrap does not send an explicit browser User-Agent.'
	$familyText = Get-Content -LiteralPath .\src\package-families.ps1 -Raw
	Assert-True ($familyText -match 'Not Found\|no upstream hash') 'Shared Adoptium package logic does not skip unavailable optional x86 assets under strict verification.'
	foreach ($patchedModule in @(
		@{ Module = 'golang.org/x/net'; Version = 'v0.56.0' },
		@{ Module = 'golang.org/x/sys'; Version = 'v0.46.0' },
		@{ Module = 'golang.org/x/text'; Version = 'v0.39.0' }
	)) {
		Assert-True ($familyText -match [regex]::Escape($patchedModule.Module)) "Shared kubectl source build omits dependency: $($patchedModule.Module)"
		Assert-True ($familyText -match [regex]::Escape($patchedModule.Version)) "Shared kubectl source build does not pin $($patchedModule.Module) to $($patchedModule.Version)."
	}
	Assert-True ($familyText -match "GoToolchain = 'go1.26.6'") 'Shared kubectl source build does not pin the fixed Go toolchain.'
	Assert-True ($familyText -match 'BuildRevision = 1') 'Shared kubectl source build does not carry a republishable package revision.'
	$cueText = Get-Content -LiteralPath .\src\pkgs\cue.ps1 -Raw
	Assert-True ($cueText -match 'Invoke-TlcVerifiedGoCommandBuild') 'Cue still packages the vulnerable upstream binary.'
	Assert-True ($cueText -match "PatchedTextVersion = 'v0\.39\.0'") 'Cue does not require the fixed golang.org/x/text version.'
	Assert-True ($cueText -match 'BuildRevision = 1') 'Cue patched source build does not carry a republishable package revision.'
	$helmText = Get-Content -LiteralPath .\src\pkgs\helm.ps1 -Raw
	Assert-True ($helmText -match 'Invoke-TlcVerifiedGoCommandBuild') 'Helm still packages the vulnerable upstream binary archive.'
	Assert-True ($helmText -match "PatchedOrasVersion = 'v2\.6\.2'") 'Helm does not require the fixed oras-go version.'
	Assert-True ($helmText -match 'BuildRevision = 1') 'Helm patched source build does not carry a republishable package revision.'
	foreach ($kubectlScript in @('.\src\pkgs\kubectl.ps1', '.\src\pkgs\kubectl-linux.ps1')) {
		$kubectlText = Get-Content -LiteralPath $kubectlScript -Raw
		Assert-True ($kubectlText -match 'Initialize-TlcKubectlPackage') "$kubectlScript bypasses the shared verified source build."
		Assert-True ($kubectlText -notmatch 'dl\.k8s\.io/release/\$tag/bin') "$kubectlScript still packages the vulnerable upstream binary."
	}
	$goSourceBuildScripts = @(
		'.\src\package-families.ps1',
		'.\src\pkgs\kind.ps1',
		'.\src\pkgs\kind-linux.ps1',
		'.\src\pkgs\k3d.ps1',
		'.\src\pkgs\k3d-linux.ps1'
	)
	foreach ($goSourceBuildScript in $goSourceBuildScripts) {
		$goSourceBuildText = Get-Content -LiteralPath $goSourceBuildScript -Raw
		Assert-True ($goSourceBuildText -match "Get-TlcApplicationPath -Name 'go'") "$goSourceBuildScript does not resolve exactly one Go executable."
		Assert-True ($goSourceBuildText -notmatch '\$go\.Source') "$goSourceBuildScript can still concatenate multiple Go command sources."
	}
	foreach ($optionalX86Script in @(
		'.\src\pkgs\jdk\jdk8.ps1', '.\src\pkgs\jdk\jdk11.ps1', '.\src\pkgs\jdk\jdk17.ps1',
		'.\src\pkgs\jre\jre8.ps1', '.\src\pkgs\jre\jre11.ps1', '.\src\pkgs\jre\jre17.ps1'
	)) {
		$optionalX86Text = Get-Content -LiteralPath $optionalX86Script -Raw
		Assert-True ($optionalX86Text -match 'Initialize-TlcAdoptiumPackage.+-IncludeX86') "$optionalX86Script does not opt in to shared optional x86 handling."
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
	foreach ($field in @('verified_downloads', 'publish_eligible', 'quarantine_reason', 'unverified_download_reason')) {
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
	$oldUserAgent = $env:TLC_USER_AGENT
	$sourcePath = Join-Path $tempRoot 'source.bin'
	$destination = Join-Path $tempRoot 'destination.bin'
	$global:TlcTestDownloadCalls = 0
	try {
		New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
		[IO.File]::WriteAllText($sourcePath, 'trusted payload')
		$expected = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
		$env:TLC_CACHE_ROOT = Join-Path $tempRoot 'cache'
		$env:TLC_REQUIRE_VERIFIED_DOWNLOADS = '1'
		Remove-Item Env:TLC_USER_AGENT -ErrorAction SilentlyContinue

		function global:Invoke-WebRequest {
			[CmdletBinding()]
			param([string]$Uri, [string]$OutFile, [hashtable]$Headers, [int]$TimeoutSec, [switch]$UseBasicParsing)
			$global:TlcTestDownloadCalls++
			Assert-True ([string]$Headers['User-Agent'] -match '^Mozilla/5\.0 .+ Chrome/[0-9]+') 'Invoke-TlcWebRequest did not pass the default browser-compatible User-Agent.'
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
		$env:TLC_USER_AGENT = $oldUserAgent
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

function Test-UpstreamMetadataParsers {
	. .\src\main.ps1
	$mavenMetadata = Get-Content -LiteralPath .\fixtures\upstream\maven-metadata.xml -Raw
	(Get-TlcMavenReleaseVersion -Metadata $mavenMetadata).ToString() | ForEach-Object {
		Assert-True ($_ -eq '3.9.12') 'Maven metadata fixture did not select the declared release version.'
	}

	$vsHistory = Get-Content -LiteralPath .\fixtures\upstream\vs-release-history.html -Raw
	$latest = Get-TlcVisualStudioBuildToolsRelease -Content $vsHistory
	Assert-True ($latest.Version.ToString() -eq '17.12.2') 'Visual Studio release fixture did not select the latest LTSC version.'
	$requested = Get-TlcVisualStudioBuildToolsRelease -Content $vsHistory -VersionWanted ([TlcSemanticVersion]::new('17.10.4'))
	Assert-True ($requested.URI -eq 'https://example.invalid/17.10/vs_BuildTools.exe') 'Visual Studio release fixture did not select an explicitly requested LTSC version.'

	$dockerDesktopAppcast = Get-Content -LiteralPath .\fixtures\upstream\docker-desktop-appcast.json -Raw | ConvertFrom-Json
	$dockerDesktop = Get-TlcDockerDesktopRelease -Metadata $dockerDesktopAppcast
	Assert-True ($dockerDesktop.VersionText -eq '4.86.0') 'Docker Desktop appcast fixture did not select the latest release.'
	Assert-True ($dockerDesktop.BuildNumber -eq '236216') 'Docker Desktop appcast fixture did not preserve the selected build number.'
	Assert-True ($dockerDesktop.URL -eq 'https://desktop.docker.com/win/main/amd64/236216/Docker%20Desktop%20Installer.exe') 'Docker Desktop appcast fixture did not select the Windows x64 EXE.'
	Assert-True ($dockerDesktop.Sha256 -eq '820438e75c16e44b393079154bea7d27958a15845c23a635b1a1f6f586b2ed44') 'Docker Desktop appcast fixture did not preserve the publisher SHA-256.'
	$invalidDockerDesktopAppcast = Get-Content -LiteralPath .\fixtures\upstream\docker-desktop-appcast.json -Raw | ConvertFrom-Json
	foreach ($item in $invalidDockerDesktopAppcast.Items) { $item.Artifacts[0].URL = 'https://example.invalid/Docker Desktop Installer.exe' }
	$offDomainRejected = $false
	try { Get-TlcDockerDesktopRelease -Metadata $invalidDockerDesktopAppcast | Out-Null } catch { $offDomainRejected = $true }
	Assert-True $offDomainRejected 'Docker Desktop appcast parser accepted an installer from outside Docker''s pinned download origin.'
	Write-Host 'Validated machine-readable and fixture-backed upstream metadata parsers.'
}

Test-PowerShellSyntax
Test-WebRequestUserAgent
Test-PackageScripts
Test-ModelCategoryMarkers
& .\scripts\test-package-spec.ps1
Test-HuggingFaceHelpers
Test-HuggingFaceLayeredDockerfile
Test-UpstreamMetadataParsers
Test-WorkflowRunnerDefaults
Test-ProductionReadinessPolicies
Test-AtomicVerifiedDownloads
Test-PackageLifecycleStateTransitions
