<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function Get-TlcHfHeaders {
	$headers = @{
		"User-Agent" = Get-TlcBrowserUserAgent
	}
	if ($env:HF_TOKEN) {
		$headers["Authorization"] = "Bearer $($env:HF_TOKEN)"
	}
	return $headers
}

function Get-TlcHfModelCacheSlug {
	param(
		[Parameter(Mandatory=$true)][string]$Repo
	)
	if ($Repo -notmatch '^[^/\s]+/[^/\s]+$') { throw "Hugging Face repository must use owner/name form: $Repo" }
	return "models--$($Repo.Replace('/', '--'))"
}

function Get-TlcHfModelVersion {
	param(
		[Parameter(Mandatory=$true)][string]$Repo,
		[hashtable]$Headers
	)

	$modelInfo = Invoke-TlcRestMethod -Uri "https://huggingface.co/api/models/$Repo" -Headers $Headers
	$lastModifiedText = [string]$modelInfo.lastModified
	if (-not $lastModifiedText) {
		throw "Could not determine lastModified for $Repo from Hugging Face."
	}

	$lastModified = [datetime]::Parse($lastModifiedText).ToUniversalTime()
	$buildComponent = [int]$lastModified.ToString('HHmm')
	return '{0}.{1}.{2}+{3}' -f $lastModified.Year, $lastModified.Month, $lastModified.Day, $buildComponent
}

function Get-TlcHfModelAllowPatterns {
	param([string[]]$ExtraPatterns)
	return @(@(
		'LICENSE'
		'LICENSE.*'
		'README.md'
		'USAGE_POLICY'
		'chat_template.jinja'
		'config.json'
		'generation_config.json'
		'merges.txt'
		'model.safetensors'
		'model-*.safetensors'
		'*.safetensors.index.json'
		'special_tokens_map.json'
		'tokenizer.json'
		'tokenizer.model'
		'tokenizer_config.json'
		'vocab.*'
	) + @($ExtraPatterns) | Select-Object -Unique)
}

function Invoke-TlcHfSnapshotDownload {
	param(
		[Parameter(Mandatory=$true)][string]$PythonPath,
		[Parameter(Mandatory=$true)][string]$Repo,
		[Parameter(Mandatory=$true)][string]$CacheDir,
		[string]$Revision,
		[string[]]$AllowPatterns
	)

	$downloadScriptPath = [System.IO.Path]::GetTempFileName()
	$stdoutPath = [System.IO.Path]::GetTempFileName()
	$stderrPath = [System.IO.Path]::GetTempFileName()
	$oldRepo = $env:TLC_HF_REPO_ID
	$oldRevision = $env:TLC_HF_REVISION
	$oldAllowPatterns = $env:TLC_HF_ALLOW_PATTERNS
	$oldHubCache = $env:HF_HUB_CACHE

	try {
		$downloadScript = @'
import os
from huggingface_hub import snapshot_download

repo_id = os.environ["TLC_HF_REPO_ID"]
revision = os.environ.get("TLC_HF_REVISION") or None
allow_patterns = [item for item in os.environ.get("TLC_HF_ALLOW_PATTERNS", "").splitlines() if item]
token = os.environ.get("HF_TOKEN") or None

path = snapshot_download(
    repo_id=repo_id,
    revision=revision,
    cache_dir=os.environ["HF_HUB_CACHE"],
    token=token,
    allow_patterns=allow_patterns or None,
)

print(path, flush=True)
'@
		Set-Content -LiteralPath $downloadScriptPath -Value $downloadScript -NoNewline

		$env:TLC_HF_REPO_ID = $Repo
		$env:TLC_HF_REVISION = $Revision
		$env:TLC_HF_ALLOW_PATTERNS = if ($AllowPatterns) { ($AllowPatterns -join "`n") } else { $null }
		$env:HF_HUB_CACHE = $CacheDir

		$downloadProc = Start-Process -FilePath $PythonPath `
			-ArgumentList @('-u', $downloadScriptPath) `
			-PassThru `
			-RedirectStandardOutput $stdoutPath `
			-RedirectStandardError $stderrPath

		$heartbeat = 0
		while (-not $downloadProc.HasExited) {
			Start-Sleep -Seconds 60
			$downloadProc.Refresh()
			if (-not $downloadProc.HasExited) {
				$heartbeat += 1
				Write-Host ("Hugging Face download still running (heartbeat {0}, utc={1})." -f $heartbeat, ([datetime]::UtcNow.ToString('o')))
			}
		}

		if (Test-Path -LiteralPath $stdoutPath) {
			Get-Content -LiteralPath $stdoutPath | ForEach-Object { Write-Host $_ }
		}
		if (Test-Path -LiteralPath $stderrPath) {
			Get-Content -LiteralPath $stderrPath | ForEach-Object { Write-Host $_ }
		}

		if ($downloadProc.ExitCode -ne 0) {
			throw "snapshot_download $Repo failed with exit code $($downloadProc.ExitCode)."
		}
	}
	finally {
		$env:TLC_HF_REPO_ID = $oldRepo
		$env:TLC_HF_REVISION = $oldRevision
		$env:TLC_HF_ALLOW_PATTERNS = $oldAllowPatterns
		$env:HF_HUB_CACHE = $oldHubCache

		foreach ($path in @($downloadScriptPath, $stdoutPath, $stderrPath)) {
			if ($path -and (Test-Path -LiteralPath $path)) {
				Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
			}
		}
	}
}
