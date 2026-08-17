<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$InputPath,
	[Parameter(Mandatory=$true)][string]$JsonOutputPath,
	[Parameter(Mandatory=$true)][string]$MarkdownOutputPath,
	[ValidateRange(1, 8760)][int]$MaxScanAgeHours = 192,
	[ValidateRange(1, 8760)][int]$MaxRemediationAgeHours = 168,
	[string]$SourceErrorPath,
	[datetime]$NowUtc = [datetime]::UtcNow,
	[switch]$Strict
)

$ErrorActionPreference = 'Stop'
$problems = [Collections.Generic.List[object]]::new()
$metrics = [Collections.Generic.List[object]]::new()
function Add-HealthProblem {
	param([string]$Package,[string]$Category,[string]$Message)
	$problems.Add([pscustomobject]@{ package=$Package; category=$Category; message=$Message })
}

$sourceError = ''
if ($SourceErrorPath -and (Test-Path -LiteralPath $SourceErrorPath -PathType Leaf)) {
	$sourceError = (Get-Content -LiteralPath $SourceErrorPath -Raw).Trim()
}
if ($sourceError) { Add-HealthProblem -Package '(catalog)' -Category Fetch -Message $sourceError }

try {
	$raw = Get-Content -LiteralPath $InputPath -Raw
	$parsed = $raw | ConvertFrom-Json
	$packages = @($parsed)
} catch {
	$packages = @()
	Add-HealthProblem -Package '(catalog)' -Category Schema -Message "Package health JSON is invalid: $($_.Exception.Message)"
}
if ($packages.Count -eq 0) {
	Add-HealthProblem -Package '(catalog)' -Category Schema -Message 'The signed package health response contains no packages.'
}

$seen = @{}
foreach ($package in $packages) {
	$name = [string]$package.Name
	if ([string]::IsNullOrWhiteSpace($name)) {
		Add-HealthProblem -Package '(unknown)' -Category Schema -Message 'A package health entry has no name.'
		continue
	}
	if ($seen.ContainsKey($name)) {
		Add-HealthProblem -Package $name -Category Schema -Message 'The package appears more than once in the health response.'
		continue
	}
	$seen[$name] = $true
	$state = [string]$package.State
	$reason = [string]$package.Reason
	if ($reason -match 'Live registry fallback|signed health metadata is unavailable') {
		Add-HealthProblem -Package $name -Category Signature -Message 'Signed catalog verification was unavailable and Toolchain used its live-registry fallback.'
	}
	if ($state -ine 'available') {
		Add-HealthProblem -Package $name -Category State -Message $(if ($reason) { "$state`: $reason" } else { "Package state is $state." })
	}
	if (@($package.Versions).Count -eq 0) {
		Add-HealthProblem -Package $name -Category Versions -Message 'No verified durable version is available.'
	}
	$scannedAt = $null
	$scanAgeHours = $null
	if (-not $package.LastScannedAt) {
		Add-HealthProblem -Package $name -Category ScanFreshness -Message 'No vulnerability scan timestamp is recorded.'
	} else {
		try {
			$scannedAt = ([datetime]$package.LastScannedAt).ToUniversalTime()
			$age = $NowUtc.ToUniversalTime() - $scannedAt
			$scanAgeHours = [Math]::Round([Math]::Max(0, $age.TotalHours), 1)
			if ($age.TotalHours -gt $MaxScanAgeHours) {
				Add-HealthProblem -Package $name -Category ScanFreshness -Message ("Latest vulnerability scan is {0:N1} hours old; maximum is {1}." -f $age.TotalHours, $MaxScanAgeHours)
			}
			if ($age.TotalMinutes -lt -5) {
				Add-HealthProblem -Package $name -Category ScanFreshness -Message 'Vulnerability scan timestamp is in the future.'
			}
		} catch {
			Add-HealthProblem -Package $name -Category Schema -Message "Invalid vulnerability scan timestamp: $($package.LastScannedAt)"
		}
	}

	$stateSince = $null
	if ($package.StateSince) {
		try { $stateSince = ([datetime]$package.StateSince).ToUniversalTime() }
		catch { Add-HealthProblem -Package $name -Category Schema -Message "Invalid state transition timestamp: $($package.StateSince)" }
	} elseif ($state -ine 'available' -and $scannedAt) {
		# Schema v1 catalogs published before state history use the latest scan as
		# a conservative lower bound until the next signed catalog refresh.
		$stateSince = $scannedAt
	}
	$lastCleanScannedAt = $null
	if ($package.LastCleanScannedAt) {
		try { $lastCleanScannedAt = ([datetime]$package.LastCleanScannedAt).ToUniversalTime() }
		catch { Add-HealthProblem -Package $name -Category Schema -Message "Invalid last clean scan timestamp: $($package.LastCleanScannedAt)" }
	} elseif ($state -ieq 'available') {
		$lastCleanScannedAt = $scannedAt
	}

	$stateAgeHours = if ($stateSince) { [Math]::Round([Math]::Max(0, ($NowUtc.ToUniversalTime() - $stateSince).TotalHours), 1) } else { $null }
	$lastCleanScanAgeHours = if ($lastCleanScannedAt) { [Math]::Round([Math]::Max(0, ($NowUtc.ToUniversalTime() - $lastCleanScannedAt).TotalHours), 1) } else { $null }
	$remediationAgeHours = if ($state -ine 'available') { $stateAgeHours } else { $null }
	$quarantinedHours = if ($state -ieq 'quarantined') { $stateAgeHours } else { $null }
	$sloStatus = if ($state -ieq 'available') {
		'not-applicable'
	} elseif ($null -eq $remediationAgeHours) {
		'unknown'
	} elseif ($remediationAgeHours -gt $MaxRemediationAgeHours) {
		'breached'
	} else {
		'within-target'
	}
	if ($sloStatus -eq 'breached') {
		Add-HealthProblem -Package $name -Category RemediationSLO -Message ("Package has remained $state for {0:N1} hours; remediation target is {1} hours." -f $remediationAgeHours, $MaxRemediationAgeHours)
	} elseif ($sloStatus -eq 'unknown') {
		Add-HealthProblem -Package $name -Category HealthHistory -Message 'No state-transition timestamp is available to measure remediation age.'
	}
	$metrics.Add([pscustomobject][ordered]@{
		package = $name
		state = $state
		stateSince = if ($stateSince) { $stateSince.ToString('o') } else { $null }
		stateAgeHours = $stateAgeHours
		remediationAgeHours = $remediationAgeHours
		quarantinedHours = $quarantinedHours
		lastScannedAt = if ($scannedAt) { $scannedAt.ToString('o') } else { $null }
		scanAgeHours = $scanAgeHours
		lastCleanScannedAt = if ($lastCleanScannedAt) { $lastCleanScannedAt.ToString('o') } else { $null }
		lastCleanScanAgeHours = $lastCleanScanAgeHours
		remediationSloStatus = $sloStatus
	})
}

$problemMetrics = @($metrics | Where-Object state -ine 'available')
$sloBreaches = @($problemMetrics | Where-Object remediationSloStatus -eq 'breached')
$sloUnknown = @($problemMetrics | Where-Object remediationSloStatus -eq 'unknown')
$sloWithinTarget = @($problemMetrics | Where-Object remediationSloStatus -eq 'within-target')
$sloCompliance = if ($problemMetrics.Count -eq 0) { 100.0 } else { 100.0 * $sloWithinTarget.Count / $problemMetrics.Count }
$report = [ordered]@{
	schemaVersion = 2
	generatedAt = $NowUtc.ToUniversalTime().ToString('o')
	healthy = ($problems.Count -eq 0)
	maxScanAgeHours = $MaxScanAgeHours
	remediationSlo = [ordered]@{
		thresholdHours = $MaxRemediationAgeHours
		trackedProblemPackages = $problemMetrics.Count
		breachCount = $sloBreaches.Count
		unknownCount = $sloUnknown.Count
		compliancePercent = [Math]::Round($sloCompliance, 1)
	}
	packageCount = $packages.Count
	problemCount = $problems.Count
	problems = @($problems)
	metrics = @($metrics)
}
foreach ($path in @($JsonOutputPath,$MarkdownOutputPath)) {
	$parent = Split-Path -Parent ([IO.Path]::GetFullPath($path))
	if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($JsonOutputPath), (($report | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# Package health monitor')
$lines.Add('')
$lines.Add("- Status: $(if ($report.healthy) { 'healthy' } else { 'unhealthy' })")
$lines.Add("- Packages checked: $($report.packageCount)")
$lines.Add("- Problems: $($report.problemCount)")
$lines.Add("- Maximum scan age: $MaxScanAgeHours hours")
$lines.Add("- Remediation SLO: $MaxRemediationAgeHours hours")
$lines.Add("- Remediation SLO breaches: $($report.remediationSlo.breachCount) of $($report.remediationSlo.trackedProblemPackages) problem packages")
$lines.Add("- Remediation ages unavailable: $($report.remediationSlo.unknownCount)")
$lines.Add("- Remediation SLO compliance: $($report.remediationSlo.compliancePercent)%")
if ($problemMetrics.Count -gt 0) {
	$lines.Add('')
	$lines.Add('| Package | State | Remediation age | Quarantined | Last clean scan | SLO |')
	$lines.Add('|---|---|---:|---:|---|---|')
	foreach ($metric in $problemMetrics | Sort-Object package) {
		$remediationAge = if ($null -ne $metric.remediationAgeHours) { "$($metric.remediationAgeHours) h" } else { 'unknown' }
		$quarantinedAge = if ($null -ne $metric.quarantinedHours) { "$($metric.quarantinedHours) h" } else { '-' }
		$lastClean = if ($metric.lastCleanScannedAt) { [string]$metric.lastCleanScannedAt } else { 'never recorded' }
		$lines.Add("| $($metric.package) | $($metric.state) | $remediationAge | $quarantinedAge | $lastClean | $($metric.remediationSloStatus) |")
	}
}
if ($problems.Count -gt 0) {
	$lines.Add('')
	$lines.Add('| Package | Category | Problem |')
	$lines.Add('|---|---|---|')
	foreach ($problem in $problems) {
		$message = ([string]$problem.message).Replace('|','\|').Replace("`r",' ').Replace("`n",' ')
		$lines.Add("| $($problem.package) | $($problem.category) | $message |")
	}
}
$lines.Add('')
$lines.Add('This report is generated from Toolchain''s Cosign-verified `tlc-catalog-v1` health path. Do not close the alert until the monitor closes it after a healthy run.')
[IO.File]::WriteAllLines([IO.Path]::GetFullPath($MarkdownOutputPath), $lines, [Text.UTF8Encoding]::new($false))

$output = [pscustomobject]$report
Write-Output $output
if ($Strict -and -not $report.healthy) { throw "Package health monitor found $($report.problemCount) problem(s)." }
