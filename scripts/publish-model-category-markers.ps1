<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
	[string]$PlanPath,
	[string]$Repository = $(if ($env:TLC_DOCKER_REPO) { $env:TLC_DOCKER_REPO } else { 'allsagetech/toolchains' }),
	[switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'src/model-catalog.ps1')

function Invoke-TlcBuildx {
	param(
		[Parameter(Mandatory=$true)][string[]]$Arguments
	)

	$oldErrorActionPreference = $ErrorActionPreference
	$oldNativePreference = $global:PSNativeCommandUseErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$global:PSNativeCommandUseErrorActionPreference = $false
		$output = @(& docker @Arguments 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $oldErrorActionPreference
		$global:PSNativeCommandUseErrorActionPreference = $oldNativePreference
	}

	if ($exitCode -ne 0) {
		$message = ($output | Out-String).Trim()
		throw "docker $($Arguments -join ' ') failed with exit code ${exitCode}: $message"
	}
	return @($output)
}

function Get-TlcDockerHubRepositoryParts {
	param([Parameter(Mandatory=$true)][string]$RepositoryName)

	if ($RepositoryName -notmatch '^([a-z0-9][a-z0-9._-]*)/([a-z0-9][a-z0-9._-]*)$') {
		throw "Model marker publication requires a Docker Hub namespace/repository, got '$RepositoryName'."
	}
	return [pscustomobject]@{ Namespace = $Matches[1]; Repository = $Matches[2] }
}

function Get-TlcValidatedMarkerPlan {
	param(
		[Parameter(Mandatory=$true)][string]$Path,
		[Parameter(Mandatory=$true)][string]$ExpectedRepository
	)

	$item = Get-Item -LiteralPath $Path -ErrorAction Stop
	if ($item.PSIsContainer -or $item.Length -lt 1 -or $item.Length -gt 1048576) {
		throw "Model marker plan must be a non-empty JSON file no larger than 1 MiB: $Path"
	}
	try {
		$document = Get-Content -LiteralPath $item.FullName -Raw | ConvertFrom-Json
	} catch {
		throw "Could not parse model marker plan '$Path': $_"
	}
	if ([int]$document.schemaVersion -ne 1) {
		throw "Unsupported model marker plan schemaVersion '$($document.schemaVersion)'."
	}
	if ([string]$document.repository -cne $ExpectedRepository) {
		throw "Model marker plan repository '$($document.repository)' does not match '$ExpectedRepository'."
	}
	if (-not @($document.PSObject.Properties.Name).Contains('desiredPackages')) {
		throw "Model marker plan '$Path' is missing desiredPackages."
	}

	$packageValues = @($document.desiredPackages)
	if ($packageValues.Count -gt $script:TlcModelCategoryMarkerMaximumCount) {
		throw "Model marker plan cannot contain more than $script:TlcModelCategoryMarkerMaximumCount packages."
	}
	$seenExact = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	$seenFolded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
	$packages = foreach ($packageValue in $packageValues) {
		if ($packageValue -isnot [string]) { throw 'Every desired model package name must be a JSON string.' }
		$package = [string]$packageValue
		Assert-TlcKindMarkerSafePackageName -Name $package
		if (-not $seenExact.Add($package)) { throw "Duplicate model package in plan: '$package'" }
		if (-not $seenFolded.Add($package)) { throw "Model package names in the plan differ only by case: '$package'" }
		$package
	}
	return @($packages | Sort-Object)
}

function Invoke-TlcHubJsonRequest {
	param(
		[Parameter(Mandatory=$true)][string]$Uri,
		[int]$MaxRetries = 5
	)

	for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
		try {
			$params = @{ Uri = $Uri; Method = 'Get'; ErrorAction = 'Stop' }
			if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey('UseBasicParsing')) { $params.UseBasicParsing = $true }
			return Invoke-RestMethod @params
		} catch {
			$statusCode = $null
			try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
			if ($attempt -ge $MaxRetries -or ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -notin 408, 429)) { throw }
			Start-Sleep -Seconds ([math]::Min(16, [math]::Pow(2, $attempt)))
		}
	}
}

function Get-TlcDockerHubTags {
	param(
		[Parameter(Mandatory=$true)][string]$RepositoryName
	)

	$parts = Get-TlcDockerHubRepositoryParts -RepositoryName $RepositoryName
	$namespace = [uri]::EscapeDataString([string]$parts.Namespace)
	$repositoryNamePart = [uri]::EscapeDataString([string]$parts.Repository)
	$url = "https://hub.docker.com/v2/namespaces/$namespace/repositories/$repositoryNamePart/tags?page_size=100"
	$tags = [Collections.Generic.List[string]]::new()
	$pageCount = 0
	while ($url) {
		$pageCount += 1
		if ($pageCount -gt 100) { throw 'Docker Hub tag listing exceeded 100 pages.' }
		$uri = [Uri]$url
		if ($uri.Scheme -ne 'https' -or $uri.Host -cne 'hub.docker.com') {
			throw "Docker Hub tag pagination returned an unsafe URL: $url"
		}
		$page = Invoke-TlcHubJsonRequest -Uri $uri.AbsoluteUri
		foreach ($result in @($page.results)) {
			if (-not [string]::IsNullOrWhiteSpace([string]$result.name)) { $tags.Add([string]$result.name) }
		}
		$url = if ($page.next) { [string]$page.next } else { $null }
	}
	return @(Get-TlcOrdinalSortedUniqueStrings -Values ([string[]]@($tags)))
}

function Get-TlcStableDockerHubTags {
	param(
		[Parameter(Mandatory=$true)][string]$RepositoryName,
		[int]$Attempts = 5,
		[int]$RequiredConsecutiveSnapshots = 2,
		[scriptblock]$TagReader,
		[scriptblock]$SleepAction = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
	)

	if (-not $TagReader) {
		$TagReader = { param($Repo) Get-TlcDockerHubTags -RepositoryName $Repo }
	}
	$previousFingerprint = $null
	$consecutive = 0
	for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
		$tags = @(Get-TlcOrdinalSortedUniqueStrings -Values ([string[]]@(& $TagReader $RepositoryName)))
		$fingerprint = $tags -join "`n"
		if ($null -ne $previousFingerprint -and $fingerprint -ceq $previousFingerprint) {
			$consecutive += 1
		} else {
			$consecutive = 1
		}
		if ($consecutive -ge $RequiredConsecutiveSnapshots) { return @($tags) }
		$previousFingerprint = $fingerprint
		if ($attempt -lt $Attempts) { & $SleepAction ([math]::Min(8, $attempt * 2)) }
	}
	throw "Docker Hub tags did not produce $RequiredConsecutiveSnapshots consecutive stable snapshots after $Attempts attempts."
}

function Get-TlcRemoteManifestDescriptor {
	param(
		[Parameter(Mandatory=$true)][string]$Reference,
		[int]$Attempts = 5,
		[scriptblock]$SleepAction = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
	)

	for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
		try {
			$json = (Invoke-TlcBuildx -Arguments @('buildx', 'imagetools', 'inspect', '--format', '{{json .Manifest}}', $Reference) | Out-String).Trim()
			$descriptor = $json | ConvertFrom-Json
			$digest = ([string]$descriptor.digest).ToLowerInvariant()
			if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "invalid manifest digest '$digest'" }
			return [pscustomobject]@{ Reference = $Reference; Digest = $digest; Descriptor = $descriptor }
		} catch {
			if ($attempt -ge $Attempts) { throw "Could not inspect manifest metadata for $Reference after $Attempts attempt(s): $_" }
			& $SleepAction ([math]::Min(8, [math]::Pow(2, $attempt)))
		}
	}
}

function Wait-TlcRemoteManifestDigest {
	param(
		[Parameter(Mandatory=$true)][string]$Reference,
		[Parameter(Mandatory=$true)][string]$ExpectedDigest,
		[int]$Attempts = 8,
		[scriptblock]$DescriptorReader,
		[scriptblock]$SleepAction = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
	)

	$expected = $ExpectedDigest.ToLowerInvariant()
	if ($expected -notmatch '^sha256:[0-9a-f]{64}$') { throw "Invalid expected manifest digest '$ExpectedDigest'." }
	if (-not $DescriptorReader) { $DescriptorReader = { param($Ref) Get-TlcRemoteManifestDescriptor -Reference $Ref -Attempts 1 } }
	$lastObserved = '<unavailable>'
	for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
		try {
			$descriptor = & $DescriptorReader $Reference
			$observed = if ($descriptor.PSObject.Properties.Name -contains 'Digest') { [string]$descriptor.Digest } else { [string]$descriptor.digest }
			$observed = $observed.ToLowerInvariant()
			if ($observed -match '^sha256:[0-9a-f]{64}$') { $lastObserved = $observed }
			if ($observed -ceq $expected) { return $descriptor }
		} catch {
			$lastObserved = '<unavailable>'
		}
		if ($attempt -lt $Attempts) { & $SleepAction ([math]::Min(8, [math]::Pow(2, $attempt))) }
	}
	throw "Registry did not report expected digest $expected for $Reference after $Attempts attempts; last observed $lastObserved."
}

function Get-TlcMarkerAnchorDescriptor {
	param(
		[Parameter(Mandatory=$true)][string]$RepositoryName,
		[Parameter(Mandatory=$true)][string[]]$RegistryTags,
		[scriptblock]$DescriptorReader
	)

	if (-not $DescriptorReader) { $DescriptorReader = { param($Ref) Get-TlcRemoteManifestDescriptor -Reference $Ref } }
	$generationMarkers = @($RegistryTags | Where-Object { $null -ne (ConvertFrom-TlcModelCategoryMarkerTag -Tag ([string]$_)) } | Sort-Object -Descending)
	$immutablePackageTags = @($RegistryTags | Where-Object {
		$_ -notlike 'tlc-kind-model-*' -and
		$_ -notlike 'staging-*' -and
		$_ -notmatch '^sha256-[0-9a-f]{64}\.' -and
		$_ -match '-[0-9]+\.[0-9]+\.[0-9]+(?:_[0-9]+)?$'
	} | Sort-Object -Descending)
	$legacyMarkers = @($RegistryTags | Where-Object { $_ -match '^tlc-kind-model--[A-Za-z0-9_][A-Za-z0-9_.-]*$' } | Sort-Object)
	$candidates = @(Get-TlcOrdinalUniqueStrings -Values ([string[]]@($generationMarkers + $immutablePackageTags + $legacyMarkers)))
	if ($candidates.Count -eq 0) { throw 'No existing category marker or immutable package version tag is available as a marker anchor.' }

	$errors = [Collections.Generic.List[string]]::new()
	foreach ($tag in $candidates) {
		$reference = "${RepositoryName}:$tag"
		try {
			$descriptor = & $DescriptorReader $reference
			$digest = if ($descriptor.PSObject.Properties.Name -contains 'Digest') { [string]$descriptor.Digest } else { [string]$descriptor.digest }
			$digest = $digest.ToLowerInvariant()
			if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "invalid manifest digest '$digest'" }
			return [pscustomobject]@{ Reference = $reference; Digest = $digest }
		} catch {
			$errors.Add("${reference}: $_")
		}
	}
	throw "No safe marker anchor could be inspected: $($errors -join '; ')"
}

function Wait-TlcCompleteModelCategoryGeneration {
	param(
		[Parameter(Mandatory=$true)][string]$RepositoryName,
		[Parameter(Mandatory=$true)][UInt64]$Generation,
		[Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$DesiredPackages,
		[int]$Attempts = 10,
		[scriptblock]$TagReader,
		[scriptblock]$SleepAction = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
	)

	if (-not $TagReader) { $TagReader = { param($Repo) Get-TlcDockerHubTags -RepositoryName $Repo } }
	for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
		$tags = @(& $TagReader $RepositoryName)
		$generationState = @(Get-TlcModelCategoryGenerations -RegistryTags $tags | Where-Object { $_.Generation -eq $Generation })
		if ($generationState.Count -eq 1 -and $generationState[0].Complete -and
			(Test-TlcModelCategoryPackageSetEqual -Left $DesiredPackages -Right @($generationState[0].Packages))) {
			return $generationState[0]
		}
		if ($attempt -lt $Attempts) { & $SleepAction ([math]::Min(10, $attempt * 2)) }
	}
	throw "Docker Hub did not report complete model category generation $Generation after $Attempts attempts."
}

function Publish-TlcModelCategoryGeneration {
	param(
		[Parameter(Mandatory=$true)][string]$RepositoryName,
		[Parameter(Mandatory=$true)][object]$PublicationPlan,
		[Parameter(Mandatory=$true)][object]$Anchor,
		[scriptblock]$BuildxInvoker,
		[scriptblock]$DigestWaiter,
		[scriptblock]$GenerationWaiter
	)

	if (-not $BuildxInvoker) {
		$BuildxInvoker = { param([string[]]$CommandArguments) Invoke-TlcBuildx -Arguments $CommandArguments }
	}
	if (-not $DigestWaiter) {
		$DigestWaiter = { param($MarkerReference, $Digest) Wait-TlcRemoteManifestDigest -Reference $MarkerReference -ExpectedDigest $Digest }
	}
	if (-not $GenerationWaiter) {
		$GenerationWaiter = { param($Repo, $GenerationNumber, [string[]]$Packages) Wait-TlcCompleteModelCategoryGeneration -RepositoryName $Repo -Generation $GenerationNumber -DesiredPackages $Packages }
	}

	$digestReference = "${RepositoryName}@$($Anchor.Digest)"
	foreach ($tag in @($PublicationPlan.MarkerTags)) {
		$markerReference = "${RepositoryName}:$tag"
		$createArguments = [string[]]@('buildx', 'imagetools', 'create', '--prefer-index=false', '--tag', $markerReference, $digestReference)
		$null = & $BuildxInvoker -CommandArguments $createArguments
		$null = & $DigestWaiter -MarkerReference $markerReference -Digest ([string]$Anchor.Digest)
		Write-Host "Published model category marker: $markerReference -> $digestReference"
	}
	$null = & $GenerationWaiter -Repo $RepositoryName -GenerationNumber ([UInt64]$PublicationPlan.Generation) -Packages ([string[]]@($PublicationPlan.DesiredPackages))
}

# Tests dot-source this file to exercise the network and propagation helpers with
# injected readers. Executable use must always provide the unprivileged plan artifact.
if ($MyInvocation.InvocationName -ne '.') {
	if ([string]::IsNullOrWhiteSpace($PlanPath)) { throw 'PlanPath is required for model category marker publication.' }

	$null = Get-TlcDockerHubRepositoryParts -RepositoryName $Repository
	$desiredPackages = @(Get-TlcValidatedMarkerPlan -Path $PlanPath -ExpectedRepository $Repository)

	# The privileged publisher re-fetches current Hub state. The plan artifact contains
	# package names only, so no package descriptor or source-tag snapshot is trusted here.
	$registryTags = @(Get-TlcStableDockerHubTags -RepositoryName $Repository)
	$publicationPlan = Get-TlcModelCategoryPublicationPlan -DesiredPackages $desiredPackages -RegistryTags $registryTags
	if (-not $publicationPlan.NeedsPublication) {
		Write-Host "Model category generation $($publicationPlan.Generation) already matches the desired package set; no publication is needed."
	} elseif ($DryRun) {
		Write-Host "Dry run: publish complete model category generation $($publicationPlan.Generation) with $($publicationPlan.MarkerTags.Count) marker tag(s)."
		foreach ($tag in @($publicationPlan.MarkerTags)) { Write-Host "Dry run: ${Repository}:$tag" }
	} else {
		if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker CLI is required to publish model category markers.' }
		$null = Invoke-TlcBuildx -Arguments @('buildx', 'version')
		$anchor = Get-TlcMarkerAnchorDescriptor -RepositoryName $Repository -RegistryTags $registryTags
		Write-Host "Using marker transport anchor $($anchor.Reference) at $($anchor.Digest)."
		Publish-TlcModelCategoryGeneration -RepositoryName $Repository -PublicationPlan $publicationPlan -Anchor $anchor
		Write-Host "Published complete model category generation $($publicationPlan.Generation) with $($publicationPlan.DesiredPackages.Count) model package(s)."
	}
}
