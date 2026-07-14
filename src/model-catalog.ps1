<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$script:TlcModelCategoryMarkerPrefix = 'tlc-kind-model-v1'
$script:TlcModelCategoryMarkerMaximumCount = 10000

function Get-TlcOrdinalUniqueStrings {
	param(
		[Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Values
	)

	$set = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	$result = [Collections.Generic.List[string]]::new()
	foreach ($value in @($Values)) {
		if ($set.Add([string]$value)) { $result.Add([string]$value) }
	}
	return @($result)
}

function Get-TlcOrdinalSortedUniqueStrings {
	param(
		[Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Values
	)

	$result = [string[]]@(Get-TlcOrdinalUniqueStrings -Values $Values)
	[Array]::Sort($result, [StringComparer]::Ordinal)
	return @($result)
}

function Assert-TlcKindMarkerSafePackageName {
	param(
		[Parameter(Mandatory=$true)][string]$Name
	)

	if ([string]::IsNullOrWhiteSpace($Name)) {
		throw 'toolchains: package name cannot be blank'
	}
	if ($Name.Contains('--')) {
		throw "toolchains: package name '$Name' contains reserved category-marker separator '--'"
	}
	if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
		throw "toolchains: package name '$Name' is not safe for an OCI tag"
	}

	$longestMarker = "$script:TlcModelCategoryMarkerPrefix-$([UInt64]::MaxValue)-$script:TlcModelCategoryMarkerMaximumCount--$Name"
	if ($longestMarker.Length -gt 128) {
		throw "toolchains: package name '$Name' is too long for a versioned category marker"
	}
}

function Get-TlcModelCategoryPackages {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][object[]]$PackageConfigs
	)

	$packagesByName = @{}
	foreach ($config in @($PackageConfigs)) {
		if ($null -eq $config) { continue }

		$name = [string]$config.Name
		Assert-TlcKindMarkerSafePackageName -Name $name

		$tier = if ([string]::IsNullOrWhiteSpace([string]$config.Tier)) { 'tooling' } else { [string]$config.Tier }
		if ($tier -notin @('tooling', 'model-small', 'model-large')) {
			throw "toolchains: unsupported package tier '$tier' for '$name'"
		}
		if ($tier -notin @('model-small', 'model-large')) { continue }

		$key = $name.ToLowerInvariant()
		if ($packagesByName.ContainsKey($key)) {
			$existing = $packagesByName[$key]
			if ([string]$existing.Package -cne $name) {
				throw "toolchains: model package names '$($existing.Package)' and '$name' differ only by case"
			}
			if ([string]$existing.Tier -ne $tier) {
				throw "toolchains: model package '$name' has conflicting tiers '$($existing.Tier)' and '$tier'"
			}
			continue
		}

		$packagesByName[$key] = [pscustomobject]@{
			Package = $name
			Tier    = $tier
		}
	}

	return @($packagesByName.Values | Sort-Object -Property Package)
}

function New-TlcModelCategoryMarkerTag {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][UInt64]$Generation,
		[Parameter(Mandatory=$true)][ValidateRange(0, 10000)][int]$Count,
		[string]$Package
	)

	if ($Generation -lt 1) { throw 'toolchains: model category marker generation must be at least 1' }
	if ($Count -eq 0) {
		if ($Package -and $Package -cne 'empty') {
			throw "toolchains: an empty model category generation must use the 'empty' sentinel"
		}
		return "$script:TlcModelCategoryMarkerPrefix-$Generation-0--empty"
	}

	Assert-TlcKindMarkerSafePackageName -Name $Package
	$tag = "$script:TlcModelCategoryMarkerPrefix-$Generation-$Count--$Package"
	if ($tag.Length -gt 128) { throw "toolchains: generated category marker is too long for an OCI tag: '$tag'" }
	return $tag
}

function ConvertFrom-TlcModelCategoryMarkerTag {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][string]$Tag
	)

	$escapedPrefix = [regex]::Escape($script:TlcModelCategoryMarkerPrefix)
	if ($Tag -notmatch "^$escapedPrefix-([0-9]+)-([0-9]+)--([A-Za-z0-9][A-Za-z0-9_.-]*)$") {
		return $null
	}

	try {
		$generation = [UInt64]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
		$count = [int]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture)
	} catch {
		return $null
	}
	if ($generation -lt 1) { return $null }
	if ($count -gt $script:TlcModelCategoryMarkerMaximumCount) { return $null }

	$package = [string]$Matches[3]
	if (($count -eq 0) -ne ($package -ceq 'empty')) { return $null }
	try { Assert-TlcKindMarkerSafePackageName -Name $package } catch { return $null }

	return [pscustomobject]@{
		Tag        = $Tag
		Generation = $generation
		Count      = $count
		Package    = if ($count -eq 0) { $null } else { $package }
		IsSentinel = $count -eq 0
	}
}

function Get-TlcModelCategoryGenerations {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][string[]]$RegistryTags
	)

	$groups = @{}
	foreach ($tagValue in @($RegistryTags)) {
		$entry = ConvertFrom-TlcModelCategoryMarkerTag -Tag ([string]$tagValue)
		if ($null -eq $entry) { continue }
		$key = ([UInt64]$entry.Generation).ToString([Globalization.CultureInfo]::InvariantCulture)
		if (-not $groups.ContainsKey($key)) { $groups[$key] = [Collections.Generic.List[object]]::new() }
		$groups[$key].Add($entry)
	}

	$generations = foreach ($key in $groups.Keys) {
		$entries = @($groups[$key])
		$counts = @($entries | Select-Object -ExpandProperty Count -Unique)
		$complete = $false
		$packages = @()
		$expectedCount = if ($counts.Count -eq 1) { [int]$counts[0] } else { -1 }

		if ($expectedCount -eq 0) {
			$complete = $entries.Count -eq 1 -and [bool]$entries[0].IsSentinel
		} elseif ($expectedCount -gt 0) {
			$packages = @(Get-TlcOrdinalSortedUniqueStrings -Values ([string[]]@($entries | Where-Object { -not $_.IsSentinel } | Select-Object -ExpandProperty Package)))
			$foldedPackages = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
			foreach ($package in $packages) { $null = $foldedPackages.Add([string]$package) }
			$complete = @($entries | Where-Object IsSentinel).Count -eq 0 -and
				$entries.Count -eq $expectedCount -and
				$packages.Count -eq $expectedCount -and
				$foldedPackages.Count -eq $expectedCount
		}

		[pscustomobject]@{
			Generation = [UInt64]$entries[0].Generation
			Count      = $expectedCount
			Packages   = @($packages)
			Tags       = @(Get-TlcOrdinalSortedUniqueStrings -Values ([string[]]@($entries.Tag)))
			Complete   = $complete
		}
	}

	return @($generations | Sort-Object -Property Generation)
}

function Test-TlcModelCategoryPackageSetEqual {
	param(
		[Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Left,
		[Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Right
	)

	$leftSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	$rightSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	foreach ($value in @($Left)) { $null = $leftSet.Add([string]$value) }
	foreach ($value in @($Right)) { $null = $rightSet.Add([string]$value) }
	return $leftSet.SetEquals($rightSet)
}

function Get-TlcModelCategoryPublicationPlan {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$DesiredPackages,
		[Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$RegistryTags
	)

	if ($DesiredPackages.Count -gt $script:TlcModelCategoryMarkerMaximumCount) {
		throw "toolchains: model category cannot contain more than $script:TlcModelCategoryMarkerMaximumCount packages"
	}
	$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	$seenFolded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
	$desired = foreach ($packageValue in @($DesiredPackages | Sort-Object)) {
		$package = [string]$packageValue
		Assert-TlcKindMarkerSafePackageName -Name $package
		if (-not $seen.Add($package)) { throw "toolchains: duplicate desired model package '$package'" }
		if (-not $seenFolded.Add($package)) { throw "toolchains: desired model package names differ only by case at '$package'" }
		$package
	}
	$desired = @($desired)

	$generations = @(Get-TlcModelCategoryGenerations -RegistryTags $RegistryTags)
	$completeGenerations = @($generations | Where-Object Complete | Sort-Object -Property Generation)
	$latestComplete = if ($completeGenerations.Count -gt 0) { $completeGenerations[-1] } else { $null }
	$highestObserved = [UInt64]0
	foreach ($generation in $generations) {
		if ([UInt64]$generation.Generation -gt $highestObserved) { $highestObserved = [UInt64]$generation.Generation }
	}
	if ($null -ne $latestComplete -and [UInt64]$latestComplete.Generation -eq $highestObserved -and
		(Test-TlcModelCategoryPackageSetEqual -Left $desired -Right @($latestComplete.Packages))) {
		return [pscustomobject]@{
			NeedsPublication = $false
			Generation       = [UInt64]$latestComplete.Generation
			DesiredPackages  = $desired
			MarkerTags       = @($latestComplete.Tags)
		}
	}

	if ($highestObserved -eq [UInt64]::MaxValue) { throw 'toolchains: model category marker generation is exhausted' }
	$nextGeneration = $highestObserved + [UInt64]1
	$count = $desired.Count
	$markerTags = if ($count -eq 0) {
		@(New-TlcModelCategoryMarkerTag -Generation $nextGeneration -Count 0)
	} else {
		@($desired | ForEach-Object { New-TlcModelCategoryMarkerTag -Generation $nextGeneration -Count $count -Package $_ })
	}

	return [pscustomobject]@{
		NeedsPublication = $true
		Generation       = $nextGeneration
		DesiredPackages  = $desired
		MarkerTags       = @($markerTags)
	}
}
