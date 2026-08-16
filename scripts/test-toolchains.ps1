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
	$modulePrefix = (Join-Path $repoRoot 'ps_modules') + [IO.Path]::DirectorySeparatorChar
	$files = Get-ChildItem -Path $repoRoot -Recurse -File |
		Where-Object { $_.Extension -eq '.ps1' -and -not $_.FullName.StartsWith($modulePrefix, [StringComparison]::OrdinalIgnoreCase) } |
		Sort-Object FullName
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

	$descriptors = @(Read-TlcPackageDescriptors -Path @($packages.FullName))
	foreach ($descriptor in $descriptors) {
		$package = Get-Item -LiteralPath $descriptor.Path
		$config = $descriptor.Config
		$tier = if ($config.Tier) { [string]$config.Tier } else { 'tooling' }
		Assert-True ($tier -in $allowedTiers) "Package $($package.FullName) has unsupported tier: $tier"

		$runsOn = Get-TlcPackageRunsOn -Config $config
		if ($tier -like 'model-*') {
			Assert-True (Test-TlcRunsOnUbuntu -RunsOn $runsOn) "Model package $($config.Name) must run on an Ubuntu runner."
		}
	}

	$descriptor = Read-TlcPackageDescriptor -Path $packages[0].FullName
	Assert-True (-not [string]::IsNullOrWhiteSpace([string]$descriptor.Config.Name)) 'Isolated descriptor reader omitted package configuration.'
	Assert-True ($null -eq (Get-Variable -Name TlcPackageConfig -Scope Global -ErrorAction SilentlyContinue)) 'Isolated descriptor reader leaked global package configuration.'
	Assert-True ($null -eq (Get-Command Install-TlcPackage -ErrorAction SilentlyContinue)) 'Isolated descriptor reader leaked package functions.'
	Write-Host "Validated $($packages.Count) package scripts."
}

function Test-ModelCategoryMarkers {
	. .\src\main.ps1

	$configs = @()
	$packagePaths = @(Get-ChildItem -Path .\src\pkgs -Filter '*.ps1' -Recurse -File | Sort-Object FullName | ForEach-Object FullName)
	foreach ($descriptor in Read-TlcPackageDescriptors -Path $packagePaths) {
		$config = $descriptor.Config
		$configs += ,[pscustomobject]@{
			Name = [string]$config.Name
			Tier = if ($config.Tier) { [string]$config.Tier } else { 'tooling' }
		}
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
	$planJobText = [regex]::Match($workflowText, '(?ms)^  model-category-marker-plan:.*?(?=^  [a-zA-Z0-9_-]+:|\z)').Value
	$publisherJobText = [regex]::Match($workflowText, '(?ms)^  model-category-markers:.*?(?=^  [a-zA-Z0-9_-]+:|\z)').Value
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

	$config = @{ Name = 'test-package' }
	Assert-True ((Get-TlcPackageRunsOn -Config $config) -eq 'windows-2022') 'Package install/test default runner should be windows-2022.'
	Assert-True ((Get-TlcPackagePublishRunsOn -Config $config) -eq 'windows-2022') 'Package publish default runner should be windows-2022.'

	Write-Host 'Validated workflow runner defaults.'
}

function Test-ProductionReadinessPolicies {
	. .\src\main.ps1

	$installerText = Get-Content -LiteralPath .\scripts\install-toolchain.ps1 -Raw
	$workflowText = Get-Content -LiteralPath .\.github\workflows\build-push.yml -Raw
	$cosignEvidenceText = Get-Content -LiteralPath .\.github\scripts\Test-CosignEvidence.ps1 -Raw
	$certificationWorkflowText = Get-Content -LiteralPath .\.github\workflows\certify-published.yml -Raw
	$promotionWorkflowText = Get-Content -LiteralPath .\.github\workflows\sync-contract.yml -Raw
	$consumerWorkflowText = Get-Content -LiteralPath .\.github\workflows\consumer-compatibility.yml -Raw
	$monitorWorkflowText = Get-Content -LiteralPath .\.github\workflows\monitor-package-health.yml -Raw
	$rollbackWorkflowText = Get-Content -LiteralPath .\.github\workflows\rollback-package.yml -Raw
	$rollbackScriptText = Get-Content -LiteralPath .\scripts\rollback-package-tag.ps1 -Raw
	$rescanPlanText = Get-Content -LiteralPath .\scripts\export-rescan-matrix.ps1 -Raw
	$consumer = Get-Content -LiteralPath .\toolchain-consumer.json -Raw | ConvertFrom-Json
	$runtimeText = Get-Content -LiteralPath .\src\package-runtime.ps1 -Raw
	Assert-True ([int]$consumer.schemaVersion -eq 1) 'Toolchain consumer manifest has an unsupported schema.'
	Assert-True ([string]$consumer.ref -match '^[0-9a-f]{40}$') 'Toolchain consumer manifest does not pin an immutable commit.'
	Assert-True ($installerText -match 'toolchain-consumer\.json') 'Toolchain installer does not read the promoted consumer manifest.'
	Assert-True ($installerText -notmatch "else \{ 'pipeline' \}") 'Toolchain installer still defaults to the mutable pipeline branch.'
	Assert-True ($installerText -notmatch '"PSModulePath=\$\(\$env:PSModulePath\)"\s*\|\s*Out-File') 'Toolchain installer exports one PowerShell edition''s module path into later consumer shells.'
	Assert-True ($workflowText -notmatch 'ref:\s*f6088e16872964cc8b5f4618a8e1bc0596822e32') 'Package contracts still use the legacy Toolchain 2.0.11 source pin.'
	Assert-True ($workflowText -notmatch '(?m)^\s*TOOLCHAIN_REF:\s*[0-9a-f]{40}\s*$') 'Package workflow duplicates the Toolchain consumer pin.'
	Assert-True ($certificationWorkflowText -notmatch '(?m)^\s*TOOLCHAIN_REF:\s*[0-9a-f]{40}\s*$') 'Certification workflow duplicates the Toolchain consumer pin.'
	Assert-True ($workflowText -match 'toolchain-consumer\.json') 'Package workflow does not resolve the promoted consumer manifest.'
	Assert-True ($workflowText -match 'ref:\s*\$\{\{ needs\.init\.outputs\.toolchain-ref \}\}') 'Package contract source does not use the manifest-derived immutable Toolchain ref.'
	Assert-True ($promotionWorkflowText -match 'update-toolchain-consumer\.ps1') 'Toolchain release synchronization does not update the consumer pin.'
	Assert-True ($promotionWorkflowText -match 'repository_dispatch:\s+types:\s*\[toolchain-released\]') 'Toolchain releases cannot trigger consumer promotion.'
	Assert-True ($promotionWorkflowText -match 'git add -- toolchain-consumer\.json schema') 'Toolchain promotion is not limited to ordinary content files.'
	Assert-True ($promotionWorkflowText -notmatch 'git add[^\r\n]+\.github/workflows') 'Toolchain promotion still attempts to modify workflow files.'
	Assert-True ($promotionWorkflowText -match 'gh pr merge[^\r\n]+--squash') 'Verified Toolchain promotions are not merged automatically.'
	Assert-True ($promotionWorkflowText -match 'REQUESTED_VERSION') 'Toolchain consumer rollback cannot select an older immutable release.'
	Assert-True ($monitorWorkflowText -match 'tlc remote health -Refresh -Json') 'Health monitoring does not use Toolchain''s signed-catalog verification path.'
	Assert-True ($monitorWorkflowText -match 'gh issue (create|edit)') 'Health monitoring does not synchronize an alert issue.'
	Assert-True ($monitorWorkflowText -match 'retention-days:\s*90') 'Health monitoring evidence is not retained for 90 days.'
	Assert-True ($rollbackWorkflowText -match "confirmation == 'ROLLBACK'") 'Package rollback lacks explicit operator confirmation.'
	foreach ($evidence in @("cosign @Arguments", "'spdxjson'", "'slsaprovenance'", 'imagetools create', 'AliasTag must be')) {
		Assert-True ($rollbackScriptText -match [regex]::Escape($evidence)) "Package rollback is missing evidence gate: $evidence"
	}
	Assert-True ($rescanPlanText -match 'Sort-Object Version -Descending') 'Scheduled rescans do not select the newest durable package version.'
	$workflowTexts = @(Get-ChildItem -LiteralPath .\.github\workflows -File -Filter '*.yml' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw })
	$uploadCount = @($workflowTexts | ForEach-Object { [regex]::Matches($_, 'uses:\s*actions/upload-artifact@') }).Count
	$retentionValues = @($workflowTexts | ForEach-Object { [regex]::Matches($_, 'retention-days:\s*([0-9]+)') | ForEach-Object { [int]$_.Groups[1].Value } })
	Assert-True ($uploadCount -eq $retentionValues.Count) 'Every uploaded workflow artifact must declare an explicit retention period.'
	Assert-True (@($retentionValues | Where-Object { $_ -lt 1 -or $_ -gt 90 }).Count -eq 0) 'Workflow artifact retention must stay within the public-repository 1-90 day policy.'
	foreach ($consumerName in @('windows-powershell-5.1','windows-powershell-7','linux-powershell-7')) {
		Assert-True ($consumerWorkflowText -match [regex]::Escape("name: $consumerName")) "Consumer compatibility matrix does not test $consumerName."
	}
	Assert-True ($consumerWorkflowText -match 'name:\s*linux-powershell-7[\s\S]+?package:\s*kubectl-linux:latest') 'Linux consumer compatibility does not use the Linux kubectl package.'
	Assert-True ($certificationWorkflowText -match 'name:\s*linux-powershell-7[\s\S]+?package:\s*kubectl-linux:latest') 'Published-package certification does not use the Linux kubectl package.'
	Assert-True ($certificationWorkflowText -match "kubectl resolved outside Toolchain's digest-addressed content store") 'Published-package certification does not reject runner-provided kubectl binaries.'
	Assert-True ($consumerWorkflowText -match 'Install promoted consumer with PowerShell 7[\s\S]+Pull, load, and inspect package under Windows PowerShell 5\.1') 'Consumer compatibility does not exercise a PowerShell 7 installer to Windows PowerShell 5.1 handoff.'
	Assert-True ($consumerWorkflowText -match 'test-toolchain-consumer\.ps1') 'Consumer compatibility does not pull and load a real published package.'
	Assert-True ($certificationWorkflowText -match "(?m)^\s{6}- name: Install pinned Toolchain consumer \(PowerShell 7\)\r?\n\s{8}if: matrix\.shell == 'pwsh'\r?\n\s{8}shell: pwsh\s*`$") 'PowerShell 7 consumer certification is not installed under PowerShell 7.'
	Assert-True ($certificationWorkflowText -match "(?m)^\s{6}- name: Install pinned Toolchain consumer \(Windows PowerShell 5\.1\)\r?\n\s{8}if: matrix\.shell == 'powershell'\r?\n\s{8}shell: powershell\s*`$") 'Windows PowerShell 5.1 consumer certification is not installed under Windows PowerShell 5.1.'

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
	foreach ($verifiedScript in @('.\src\pkgs\nasm.ps1', '.\src\pkgs\zstd.ps1')) {
		$config = (Read-TlcPackageDescriptor -Path $verifiedScript).Config
		$text = Get-Content -LiteralPath $verifiedScript -Raw
		Assert-True (Get-TlcPackagePublicationState -Config $config).VerifiedDownloads "$verifiedScript remains provenance-quarantined."
		Assert-True ($text -match 'ExpectedSha256') "$verifiedScript does not pass its reviewed SHA-256 to the common downloader."
		Assert-True ($text -match 'microsoft/winget-pkgs commit') "$verifiedScript does not identify the independent checksum provenance."
	}
	$dockerPackageText = Get-Content -LiteralPath .\src\pkgs\docker.ps1 -Raw
	Assert-True ($dockerPackageText -match "GoToolchain = 'go1\.26\.6'") 'Docker CLI is not rebuilt with the patched Go toolchain.'
	Assert-True ($dockerPackageText -match "UpstreamCommit = '[0-9a-f]{40}'") 'Docker CLI source is not pinned to an immutable upstream commit.'
	Assert-True ($dockerPackageText -match "MobyCommit = '[0-9a-f]{40}'") 'Docker daemon source is not pinned to an immutable upstream commit.'
	Assert-True ($dockerPackageText -match 'ExpectedSha256') 'Docker CLI source archive is not checksum pinned.'
	Assert-True ($dockerPackageText -match 'MobyExpectedSha256') 'Docker daemon source archive is not checksum pinned.'
	Assert-True ($dockerPackageText -match "Invoke-TlcNativeCommand[\s\S]+?'build', '-buildvcs=false', '-trimpath'") 'Docker CLI is not built reproducibly from pinned source.'
	Assert-True ($dockerPackageText -notmatch '& \$go') 'Docker Go commands bypass native exit-code isolation.'
	Assert-True ($dockerPackageText -match "GoWinresVersion = 'v0\.3\.3'") 'Docker daemon Windows resource generator is not version pinned.'
	Assert-True ($dockerPackageText -match 'go-winres build tool provenance') 'Docker daemon resource generator provenance is not verified.'
	Assert-True ($dockerPackageText -match 'dockerd --version') 'Docker daemon compatibility validation is missing.'
	Assert-True ($dockerPackageText -notmatch 'download\.docker\.com/win/static') 'Docker package still consumes the vulnerable prebuilt Windows bundle.'
	$nodeFamilyText = Get-Content -LiteralPath .\src\package-families.ps1 -Raw
	Assert-True ($nodeFamilyText -match 'Invoke-TlcWebRequest[\s\S]+-ExpectedHashAlgorithm SHA512') 'Pinned npm archives are not verified with registry SHA-512 integrity.'
	Assert-True ($nodeFamilyText -match "'-tzf'[\s\S]+contains an unsafe path") 'Pinned npm archives are not checked for path traversal before extraction.'
	Assert-True ($nodeFamilyText -match "'-tvzf'[\s\S]+contains links") 'Pinned npm archives do not reject links before extraction.'
	Assert-True ($nodeFamilyText -match 'npm archive identity mismatch') 'Pinned npm archive name and version are not verified after extraction.'
	foreach ($nodeMajor in @(22, 24)) {
		$config = (Read-TlcPackageDescriptor -Path ".\src\pkgs\node\node$nodeMajor.ps1").Config
		$nodePublication = Get-TlcPackagePublicationState -Config $config
		Assert-True $nodePublication.VerifiedDownloads "Node $nodeMajor archive is not checksum verified."
		Assert-True $nodePublication.PublishEligible "Node $nodeMajor remains statically quarantined after the upstream security release."
		Assert-True ($config.BuildRevision -eq 1) "Node $nodeMajor patched package does not carry a republishable build revision."
		Assert-True ($config.NpmVersion -eq '12.0.2') "Node $nodeMajor does not pin the remediated npm release."
		Assert-True ($config.NpmExpectedSha512 -match '^[0-9a-f]{128}$') "Node $nodeMajor npm archive does not pin registry SHA-512 integrity."
		Assert-True ($config.NpmDependencyOverlays['brace-expansion'].Version -eq '5.0.9') "Node $nodeMajor does not overlay the fixed brace-expansion release."
		Assert-True ($config.NpmDependencyOverlays['ip-address'].Version -eq '10.5.0') "Node $nodeMajor does not overlay the fixed ip-address release."
		foreach ($overlayName in @('brace-expansion', 'ip-address')) {
			Assert-True ($config.NpmDependencyOverlays[$overlayName].ExpectedSha512 -match '^[0-9a-f]{128}$') "Node $nodeMajor $overlayName overlay does not pin registry SHA-512 integrity."
		}
	}
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
	$integrityText = Get-Content -LiteralPath .\src\integrity.ps1 -Raw
	$huggingFaceImageText = Get-Content -LiteralPath .\src\huggingface-image.ps1 -Raw
	$localExecText = Get-Content -LiteralPath .\src\local-exec.ps1 -Raw
	Assert-True ($integrityText -match '\$assetName\.sha256\.txt') 'GitHub release verification does not discover publisher companion SHA-256 assets.'
	Assert-True ($utilText -match '/releases/latest') 'GitHub release discovery does not prefer the bounded latest-release endpoint.'
	Assert-True ($utilText -match 'releases\?per_page=20') 'GitHub release fallback still requests oversized release-history pages.'
	Assert-True ($localExecText -match "OSPlatform\]::Windows\)\) \{ 'Path' \} else \{ 'PATH' \}") 'Local execution does not normalize PATH casing for Linux hosts.'
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
	foreach ($familyRepresentative in @('src/pkgs/node/node22.ps1', 'src/pkgs/jdk/jdk17.ps1', 'src/pkgs/kubectl.ps1', 'src/pkgs/kubectl-linux.ps1', 'src/pkgs/k9s.ps1', 'src/pkgs/k9s-linux.ps1')) {
		Assert-True ($familyPushSelection -contains $familyRepresentative) "Shared package-family changes omit representative $familyRepresentative."
	}
	Assert-True (@(Get-TlcPushPackagePaths -ChangedPath @('README.md', 'CHANGELOG.md')).Count -eq 0) 'Documentation-only pushes still select publication jobs.'
	$workflowText = Get-Content -LiteralPath .\.github\workflows\build-push.yml -Raw
	Assert-True ($runtimeText -match '\$global:TlcPackageConfig\.Tags\s*=\s*@\(\)') 'Forced PR smoke builds do not clear published package tags in the isolated runtime.'
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
	Assert-True ($workflowText -match 'Test-CosignEvidence\.ps1') 'Publication does not use the shared fail-closed Cosign evidence verifier.'
	Assert-True ($cosignEvidenceText -match 'function Invoke-CosignVerification') 'Cosign verification has no bounded retry wrapper.'
	Assert-True ($cosignEvidenceText -match "'--offline', '--timeout', '30s'") 'Cosign verification does not use the signed transparency bundle with a bounded internal timeout.'
	Assert-True ($workflowText -match 'Verify signature and attestations fail closed[\s\S]+timeout-minutes:\s+6') 'Cosign verification step has no GitHub-enforced deadline.'
	Assert-True ($cosignEvidenceText -match 'Redirected Process streams can keep a[\s\S]+Windows child attached indefinitely') 'Cosign verification does not document why child-process output must remain inherited.'
	Assert-True ($cosignEvidenceText -notmatch 'RedirectStandardOutput|RedirectStandardError|-RedirectStandardOutput|-RedirectStandardError') 'Cosign verification still redirects child-process output and can deadlock the Windows runner.'
	Assert-True ($cosignEvidenceText -notmatch 'ReadToEndAsync|GetAwaiter\(\)\.GetResult\(\)') 'Cosign verification can still hang while draining a terminated child process.'
	Assert-True ($cosignEvidenceText -match '\$process\.WaitForExit\(\$TimeoutSeconds \* 1000\)') 'Cosign verification has no external hard timeout.'
	Assert-True ($cosignEvidenceText -match '\$process\.Kill\(\)' -and $cosignEvidenceText -match '\$process\.WaitForExit\(5000\)') 'Cosign verification does not terminate and reap a timed-out process.'
	Assert-True ($cosignEvidenceText -notmatch '\$process\.Kill\(\$true\)') 'Cosign verification still uses blocking process-tree enumeration on timeout.'
	Assert-True ($workflowText -match 'Publish platform leaf alias[\s\S]+if: steps\.pkg\.outputs\.canonical-name != '''' && steps\.pkg\.outputs\.platform != ''''[\s\S]+Test-CosignEvidence\.ps1') 'An already-current package cannot safely repair a missing verified platform alias.'
	Assert-True ($workflowText -match 'imagetools'', ''create''[\s\S]+imagetools create --help|\$helpArguments = @\(\$createArguments \+ ''--help''\)') 'Platform alias publication does not inspect Docker Buildx capabilities.'
	Assert-True ($workflowText -match 'if \(\$imagetoolsHelp -match [\s\S]+\$createArguments \+= ''--prefer-index=false''[\s\S]+& docker @createArguments') 'Platform alias publication does not conditionally use --prefer-index with a compatible fallback.'
	Assert-True ($workflowText -notmatch 'docker buildx imagetools create --prefer-index=false') 'Platform alias publication still unconditionally requires a newer Docker Buildx client.'
	Assert-True ($workflowText -match '\$createArguments \+= @\(''-t'', \$leafTag, \$digestRef\)') 'Platform alias publication does not use the legacy-compatible Buildx tag option.'
	Assert-True ($workflowText -match 'docker manifest inspect --verbose \$immutableTag[\s\S]+docker manifest inspect --verbose \$leafTag[\s\S]+platform leaf alias does not contain its signed package digest') 'Platform alias publication does not verify its signed digest through the Docker manifest API.'
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
	$windowsDockerfileText = Get-Content -LiteralPath .\Dockerfile -Raw
	Assert-True ($windowsDockerfileText -match '(?m)^FROM mcr\.microsoft\.com/windows/nanoserver:ltsc2022@sha256:[0-9a-f]{64}\s*$') 'Windows package images do not pin the Nano Server base by digest.'
	Assert-True ($huggingFaceImageText -match "FROM ubuntu:22\.04@sha256:[0-9a-f]{64}") 'Generated layered Linux images do not pin Ubuntu by digest.'
	$openAiModelText = Get-Content -LiteralPath .\src\pkgs\openai-gpt-oss-20b.ps1 -Raw
	Assert-True ($openAiModelText -match "FROM ubuntu:22\.04@sha256:[0-9a-f]{64}") 'The custom OpenAI model image does not pin Ubuntu by digest.'
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
	Assert-True ($stagingCleanupWorkflowText -match 'include_quarantined_packages:[\s\S]+default:\s+true') 'Scheduled cleanup does not remove quarantined package tags.'
	Assert-True ($stagingCleanupWorkflowText -match 'Remove-DockerHubQuarantinedTags\.ps1') 'Docker Hub cleanup does not enforce descriptor quarantine state.'
	Assert-True ($stagingCleanupWorkflowText -match 'dry_run:[\s\S]+default:\s+true') 'Manual Docker Hub cleanup is destructive by default.'
	Assert-True ($workflowText -match 'group:\s+toolchains-package-publication-' -and $stagingCleanupWorkflowText -match 'group:\s+toolchains-package-publication-refs/heads/main') 'Cleanup can race main package publication.'
	$quarantineCleanupText = Get-Content -LiteralPath .\.github\scripts\Remove-DockerHubQuarantinedTags.ps1 -Raw
	Assert-True ($quarantineCleanupText -match 'Get-TlcPackagePublicationState') 'Quarantine cleanup does not derive deletion state from package descriptors.'
	Assert-True ($quarantineCleanupText -match 'Partially quarantined package.+requires a tag Matcher') 'Partial-family quarantine cleanup can delete supported package versions.'
	Assert-True ($quarantineCleanupText -match '\$remainingDurableDigests\.ContainsKey\(\$subjectDigest\)') 'Quarantine cleanup can delete Cosign attachments shared with a durable package tag.'
	Assert-True ($quarantineCleanupText -match '/namespaces/\$namespaceSegment/repositories/\$repositorySegment/tags/\$tagSegment') 'Quarantine cleanup does not delete one exact Docker Hub tag.'
	Assert-True ($quarantineCleanupText -notmatch '/manifests/') 'Quarantine cleanup can delete a shared registry manifest instead of one tag.'
	Assert-True ($quarantineCleanupText -match 'if \(\$DryRun\)') 'Quarantine cleanup has no non-destructive preview mode.'
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
	foreach ($patchedModule in @(
		@{ Module = 'github.com/containerd/containerd'; Version = 'v1.7.33' },
		@{ Module = 'github.com/containerd/containerd/v2'; Version = 'v2.2.5' },
		@{ Module = 'github.com/go-git/go-git/v5'; Version = 'v5.19.2' },
		@{ Module = 'golang.org/x/crypto'; Version = 'v0.53.0' },
		@{ Module = 'golang.org/x/net'; Version = 'v0.56.0' },
		@{ Module = 'golang.org/x/text'; Version = 'v0.39.0' },
		@{ Module = 'google.golang.org/grpc'; Version = 'v1.82.1' },
		@{ Module = 'oras.land/oras-go/v2'; Version = 'v2.6.2' }
	)) {
		Assert-True ($familyText -match [regex]::Escape($patchedModule.Module)) "Shared K9s source build omits dependency: $($patchedModule.Module)"
		Assert-True ($familyText -match [regex]::Escape($patchedModule.Version)) "Shared K9s source build does not pin $($patchedModule.Module) to $($patchedModule.Version)."
	}
	Assert-True ($familyText -match 'Initialize-TlcK9sPackage[\s\S]+?BuildRevision = 1[\s\S]+?Invoke-TlcVerifiedGoCommandBuild') 'Shared K9s source build does not carry a republishable package revision.'
	Assert-True ($familyText -match "UpstreamVersion = '0\.51\.0'") 'Shared K9s source build does not pin upstream v0.51.0.'
	Assert-True ($familyText -match "UpstreamCommit = '558caafe7ba067467de46b320cc22ef11fef9c34'") 'Shared K9s source build does not pin the v0.51.0 commit.'
	foreach ($k9sScript in @('.\src\pkgs\k9s.ps1', '.\src\pkgs\k9s-linux.ps1')) {
		$k9sText = Get-Content -LiteralPath $k9sScript -Raw
		Assert-True ($k9sText -match 'Initialize-TlcK9sPackage') "$k9sScript bypasses the shared verified source build."
	}
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
		'.\src\pkgs\k3d-linux.ps1',
		'.\src\pkgs\docker.ps1'
	)
	foreach ($goSourceBuildScript in $goSourceBuildScripts) {
		$goSourceBuildText = Get-Content -LiteralPath $goSourceBuildScript -Raw
		Assert-True ($goSourceBuildText -match "Get-TlcApplicationPath -Name 'go'") "$goSourceBuildScript does not resolve exactly one Go executable."
		Assert-True ($goSourceBuildText -notmatch '\$go\.Source') "$goSourceBuildScript can still concatenate multiple Go command sources."
		Assert-True ($goSourceBuildText -match 'Invoke-TlcNativeCommand') "$goSourceBuildScript bypasses native exit-code isolation."
		Assert-True ($goSourceBuildText -notmatch '(?m)&\s+(?:\$go|go)\s+(?:build|get|install|list|mod)\b') "$goSourceBuildScript can still turn successful Go stderr into a package failure."
	}
	$dependabotText = Get-Content -LiteralPath .\src\pkgs\dependabot.ps1 -Raw
	Assert-True ($dependabotText -match 'Invoke-TlcVerifiedGoCommandBuild') 'Dependabot does not use the isolated checksum-database-verified Go source build.'
	Assert-True ($dependabotText -match 'ForbiddenPackagePrefixes') 'Dependabot does not verify that the VEX-covered authorization package is absent.'
	Assert-True ($dependabotText -match 'BuildRevision = 1') 'Dependabot hardened package does not carry a republishable build revision.'
	Assert-True ($dependabotText -notmatch '(?m)\$env:(?:GOPATH|GOMODCACHE)\s*=') 'Dependabot can still publish its Go module cache and fixture private keys.'
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

function Test-PlatformIndexMigrationPlan {
	$tempPath = Join-Path ([IO.Path]::GetTempPath()) ("toolchains-platform-plan-$([Guid]::NewGuid().ToString('n')).json")
	try {
		& .\scripts\export-platform-index-plan.ps1 -OutputPath $tempPath -Repository 'owner/repo' -Tags @(
			'kubectl-1.34.0_1',
			'kubectl-linux-1.34.0_1'
		)
		$plan = Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json
		$entry = @($plan.indexes | Where-Object target -eq 'owner/repo:kubectl-1.34.0_1')
		Assert-True ($entry.Count -eq 1) 'First-run platform migration did not plan the existing kubectl pair.'
		Assert-True (@($entry[0].sources) -contains 'owner/repo:kubectl-1.34.0_1') 'Platform migration omitted the existing Windows durable tag.'
		Assert-True (@($entry[0].sources) -contains 'owner/repo:kubectl-linux-1.34.0_1') 'Platform migration omitted the existing Linux durable tag.'
		Assert-True (@($entry[0].leafTags).Count -eq 2) 'Platform migration did not seed two immutable platform leaves.'
	} finally {
		if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force }
	}
	Write-Host 'Validated first-run multi-platform index migration.'
}

function Test-SemanticVersionValidation {
	. .\src\main.ps1
	([TlcSemanticVersion]::new()).ToString() | ForEach-Object { Assert-True ($_ -eq '0.0.0') 'Empty semantic-version sentinel changed.' }
	Assert-True (([TlcSemanticVersion]::new('1.2.3+4')).ToString() -eq '1.2.3+4') 'Valid semantic version was parsed incorrectly.'
	Assert-True ([TlcSemanticVersion]::new('2.0.0').LaterThan([TlcSemanticVersion]::new('1.9.9'))) 'Semantic version ordering is incorrect.'
	$invalidRejected = $false
	try { $null = [TlcSemanticVersion]::new('not-a-version') } catch { $invalidRejected = $true }
	Assert-True $invalidRejected 'Invalid semantic versions fail open as 0.0.0.'
	$patternMismatchRejected = $false
	try { $null = [TlcSemanticVersion]::new('release-x', '^v([0-9]+)\.([0-9]+)\.([0-9]+)$') } catch { $patternMismatchRejected = $true }
	Assert-True $patternMismatchRejected 'Custom semantic-version pattern mismatches fail open.'
	Write-Host 'Validated fail-closed semantic version parsing.'
}

function Test-PackageInventory {
	$attributes = Get-Content -LiteralPath .\.gitattributes -Raw
	Assert-True ($attributes -match '(?m)^/PACKAGE_INVENTORY\.md\s+text\s+eol=lf\s*$') 'PACKAGE_INVENTORY.md is not pinned to LF for deterministic Windows checkouts.'
	$tempPath = Join-Path ([IO.Path]::GetTempPath()) ("toolchains-inventory-$([Guid]::NewGuid().ToString('n')).md")
	try {
		& .\scripts\export-package-inventory.ps1 -OutputPath $tempPath | Out-Null
		$expected = Get-Content -LiteralPath .\PACKAGE_INVENTORY.md -Raw
		$actual = Get-Content -LiteralPath $tempPath -Raw
		Assert-True ($actual -ceq $expected) 'PACKAGE_INVENTORY.md is stale; run ./scripts/export-package-inventory.ps1.'
	} finally {
		Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
	}
	Write-Host 'Validated generated package inventory.'
}

function Invoke-ToolchainsValidation {
	Test-PowerShellSyntax
	Test-WebRequestUserAgent
	Test-PackageScripts
	Test-ModelCategoryMarkers
	& .\scripts\test-package-spec.ps1
	Test-HuggingFaceHelpers
	Test-HuggingFaceLayeredDockerfile
	Test-UpstreamMetadataParsers
	Test-PlatformIndexMigrationPlan
	Test-WorkflowRunnerDefaults
	Test-ProductionReadinessPolicies
	Test-AtomicVerifiedDownloads
	Test-PackageLifecycleStateTransitions
	Test-SemanticVersionValidation
	Test-PackageInventory
}

if ($MyInvocation.InvocationName -ne '.') {
	Invoke-ToolchainsValidation
}
