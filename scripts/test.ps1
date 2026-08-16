<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
	[ValidateRange(0, 100)]
	[double]$CoverageTarget = 50
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$moduleRoot = Join-Path $repoRoot 'ps_modules'
if (-not (Test-Path -LiteralPath $moduleRoot -PathType Container)) {
	New-Item -Path $moduleRoot -ItemType Directory | Out-Null
}

function Import-TlcTestModule {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[Parameter(Mandatory=$true)][version]$RequiredVersion
	)

	$localModule = Join-Path $moduleRoot $Name
	$candidates = @()
	if (Test-Path -LiteralPath $localModule -PathType Container) {
		foreach ($manifest in Get-ChildItem -Path $localModule -Recurse -File -Filter "$Name.psd1") {
			try {
				$info = Test-ModuleManifest -Path $manifest.FullName -ErrorAction Stop
				if ($info.Version -eq $RequiredVersion) { $candidates += $manifest.FullName }
			} catch { Write-Debug "Skipping invalid test-module manifest '$($manifest.FullName)': $($_.Exception.Message)" }
		}
	}

	if ($candidates.Count -eq 0) {
		try { Save-Module -Name $Name -RequiredVersion $RequiredVersion -Path $moduleRoot -ErrorAction Stop }
		catch { Write-Warning "Could not download $Name $RequiredVersion; checking installed modules." }
		if (Test-Path -LiteralPath $localModule -PathType Container) {
			foreach ($manifest in Get-ChildItem -Path $localModule -Recurse -File -Filter "$Name.psd1") {
				try {
					$info = Test-ModuleManifest -Path $manifest.FullName -ErrorAction Stop
					if ($info.Version -eq $RequiredVersion) { $candidates += $manifest.FullName }
				} catch { Write-Debug "Skipping invalid test-module manifest '$($manifest.FullName)': $($_.Exception.Message)" }
			}
		}
	}

	$candidates += @(Get-Module -ListAvailable -Name $Name | Where-Object Version -eq $RequiredVersion | ForEach-Object Path)
	$selected = @($candidates | Select-Object -Unique | Select-Object -First 1)
	if ($selected.Count -eq 0) {
		throw "$Name $RequiredVersion is required. Restore it from PowerShell Gallery or pre-populate '$moduleRoot'."
	}
	Remove-Module -Name $Name -Force -ErrorAction SilentlyContinue
	Import-Module -Name $selected[0] -Force -ErrorAction Stop
}

$dependencies = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'test.dependencies.psd1')
foreach ($dependency in $dependencies.GetEnumerator()) {
	Import-TlcTestModule -Name $dependency.Key -RequiredVersion ([version]$dependency.Value)
}

$analysisRoots = @('src', 'scripts', '.github/scripts') | ForEach-Object { Join-Path $repoRoot $_ }
$settingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
foreach ($analysisRoot in $analysisRoots) {
	$findings = @(Invoke-ScriptAnalyzer -Path $analysisRoot -Recurse -Settings $settingsPath)
	if ($findings.Count -gt 0) {
		$findings | Format-Table -Wrap | Out-String | Write-Error
		throw "PSScriptAnalyzer found $($findings.Count) actionable issue(s) in $analysisRoot."
	}
}

if ($env:TOOLCHAINS_COVERAGE_TARGET) {
	$CoverageTarget = [double]$env:TOOLCHAINS_COVERAGE_TARGET
}

$coveragePaths = @(
	'src/cache.ps1'
	'src/definition-file.ps1'
	'src/huggingface-download.ps1'
	'src/huggingface-image.ps1'
	'src/integrity.ps1'
	'src/local-exec.ps1'
	'src/main.ps1'
	'src/model-catalog.ps1'
	'src/network.ps1'
	'src/package-families.ps1'
	'src/package-runtime.ps1'
	'src/semantic-version.ps1'
	'src/upstream-metadata.ps1'
	'src/util.ps1'
) | ForEach-Object { Join-Path $repoRoot $_ }

$configuration = New-PesterConfiguration -Hashtable @{
	Run = @{
		Path = $PSScriptRoot
		Exit = $false
		PassThru = $true
	}
	CodeCoverage = @{
		Enabled = ($CoverageTarget -gt 0)
		Path = $coveragePaths
		CoveragePercentTarget = $CoverageTarget
		OutputFormat = 'JaCoCo'
		OutputPath = Join-Path $repoRoot 'coverage.xml'
	}
	TestResult = @{
		Enabled = $true
		OutputFormat = 'NUnitXml'
		OutputPath = Join-Path $repoRoot 'test-results.xml'
	}
	Output = @{ Verbosity = 'Detailed' }
}

$result = Invoke-Pester -Configuration $configuration
if ($result.Result -ne 'Passed' -or $result.FailedCount -gt 0) {
	throw "Pester failed with $($result.FailedCount) failing test(s)."
}

if ($CoverageTarget -gt 0) {
	$coverageDocument = [xml](Get-Content -LiteralPath (Join-Path $repoRoot 'coverage.xml') -Raw)
	$counter = $coverageDocument.DocumentElement.SelectSingleNode("counter[@type='INSTRUCTION']")
	if (-not $counter) { throw 'Coverage report does not contain an INSTRUCTION counter.' }
	$covered = [double]$counter.covered
	$total = $covered + [double]$counter.missed
	$percent = if ($total -eq 0) { 100.0 } else { 100.0 * $covered / $total }
	if ($percent -lt $CoverageTarget) {
		throw ('Code coverage {0:N2}% is below the required {1:N2}%.' -f $percent, $CoverageTarget)
	}
}
