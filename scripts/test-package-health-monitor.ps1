<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$InputPath,
	[Parameter(Mandatory=$true)][string]$JsonOutputPath,
	[Parameter(Mandatory=$true)][string]$MarkdownOutputPath,
	[ValidateRange(1, 8760)][int]$MaxScanAgeHours = 192,
	[string]$SourceErrorPath,
	[datetime]$NowUtc = [datetime]::UtcNow,
	[switch]$Strict
)

$ErrorActionPreference = 'Stop'
$problems = [Collections.Generic.List[object]]::new()
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
	if (-not $package.LastScannedAt) {
		Add-HealthProblem -Package $name -Category ScanFreshness -Message 'No vulnerability scan timestamp is recorded.'
	} else {
		try {
			$scannedAt = ([datetime]$package.LastScannedAt).ToUniversalTime()
			$age = $NowUtc.ToUniversalTime() - $scannedAt
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
}

$report = [ordered]@{
	schemaVersion = 1
	generatedAt = $NowUtc.ToUniversalTime().ToString('o')
	healthy = ($problems.Count -eq 0)
	maxScanAgeHours = $MaxScanAgeHours
	packageCount = $packages.Count
	problemCount = $problems.Count
	problems = @($problems)
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
