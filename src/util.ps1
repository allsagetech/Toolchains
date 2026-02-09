<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

Class TlcSemanticVersion : System.IComparable {

	[int]$Major = 0
	[int]$Minor = 0
	[int]$Patch = 0
	[int]$Build = 0

	hidden init([string]$tag, [string]$pattern) {
		if ($tag -match $pattern) {
			$this.Major = if ($Matches[1]) { $Matches[1] } else { 0 }
			$this.Minor = if ($Matches[2]) { $Matches[2] } else { 0 }
			$this.Patch = if ($Matches[3]) { $Matches[3] } else { 0 }
			$this.Build = if ($Matches[4]) { [Regex]::Replace("$($Matches[4])", '[^0-9]+', '') } else { 0 }
		}
	}

	TlcSemanticVersion([string]$tag, [string]$pattern) {
		$this.init($tag, $pattern)
	}

	TlcSemanticVersion([string]$version) {
		$this.init($version, '^([0-9]+)\.([0-9]+)\.([0-9]+)([+.][0-9]+)?$')
	}

	TlcSemanticVersion() { }

	[bool] LaterThan([object]$Obj) {
		return $this.CompareTo($obj) -lt 0
	}

	[int] CompareTo([object]$Obj) {
		if ($Obj -isnot $this.GetType()) {
			throw "cannot compare types $($Obj.GetType()) and $($this.GetType())"
		} elseif ((($i = $Obj.Major.CompareTo($this.Major)) -ne 0) -or (($i = $Obj.Minor.CompareTo($this.Minor)) -ne 0) -or (($i = $Obj.Patch.CompareTo($this.Patch)) -ne 0)) {
			return $i
		}
		return $Obj.Build.CompareTo($this.Build)
	}

	[bool] Equals([object]$Obj) {
		return $Obj -is $this.GetType() -and $Obj.Major -eq $this.Major -and $Obj.Minor -eq $this.Minor -and $Obj.Patch -eq $this.Patch -and $Obj.Build -eq $this.Build
	}

	[string] ToString() {
		return "$($this.Major).$($this.Minor).$($this.Patch)$(if ($this.Build) {"+$($this.Build)"})"
	}

}

function Get-TlcGitHubHeaders {
	$headers = @{
		"User-Agent" = "allsagetech-toolchains"
		"Accept" = "application/vnd.github+json"
		"X-GitHub-Api-Version" = "2022-11-28"
	}
	$token = $env:GH_TOKEN
	if (-not $token) { $token = $env:GITHUB_TOKEN }
	if ($token) {
		$headers["Authorization"] = "Bearer $token"
	}
	return $headers
}

function Invoke-TlcRestMethod {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Uri,
		[hashtable]$Headers,
		[int]$TimeoutSec = 120,
		[int]$MaxRetries = 8,
		[int]$RetryDelaySeconds = 2
	)
	$ErrorActionPreference = 'Stop'
	for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
		try {
			$Params = @{ Uri = $Uri; ErrorAction = 'Stop'; TimeoutSec = $TimeoutSec }
			if ($Headers) { $Params.Headers = $Headers }
			return (Invoke-RestMethod @Params)
		} catch {
			$statusCode = $null
			try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
			if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and ($statusCode -notin 408, 429)) { throw }

			if ($attempt -ge $MaxRetries) { throw }
			$delay = [math]::Min(60, $RetryDelaySeconds * [math]::Pow(2, ($attempt - 1)))
			$retryAfter = $null
			try { $retryAfter = $_.Exception.Response.Headers['Retry-After'] } catch { }
			if ($retryAfter) {
				[int]$raSec = 0
				if ([int]::TryParse([string]$retryAfter, [ref]$raSec)) {
					$delay = [math]::Max($delay, $raSec)
				} else {
					try {
						$raDate = [datetime]::Parse([string]$retryAfter)
						$raDelta = [int]([math]::Ceiling(($raDate.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds))
						if ($raDelta -gt 0) { $delay = [math]::Max($delay, $raDelta) }
					} catch { }
				}
			}
			Write-Host "request failed (attempt $attempt/$MaxRetries); retrying in $delay sec: $($_.Exception.Message)"
			Start-Sleep -Seconds $delay
		}
	}
}

function Invoke-TlcWebRequest {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)][string]$Uri,
		[string]$OutFile,
		[hashtable]$Headers,
		[int]$TimeoutSec = 300,
		[int]$MaxRetries = 8,
		[int]$RetryDelaySeconds = 2
	)
	$ErrorActionPreference = 'Stop'
	$hasUseBasicParsing = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('UseBasicParsing')

	$cacheFile = $null
	if ($OutFile) {
		try {
			$ext = [IO.Path]::GetExtension($OutFile)
			if (-not $ext) { $ext = [IO.Path]::GetExtension(([Uri]$Uri).AbsolutePath) }
			$cacheFile = Get-TlcCachePathForUri -Uri $Uri -Extension ($ext.TrimStart('.'))
			if ($cacheFile -and (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
				Copy-Item -LiteralPath $cacheFile -Destination $OutFile -Force
				return [pscustomobject]@{ StatusCode = 200; FromCache = $true; Path = $OutFile }
			}
		} catch { }
	}
	for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
		try {
			$Params = @{ Uri = $Uri; ErrorAction = 'Stop'; TimeoutSec = $TimeoutSec }
			if ($OutFile) { $Params.OutFile = $OutFile }
			if ($Headers) { $Params.Headers = $Headers }
			if ($hasUseBasicParsing) { $Params.UseBasicParsing = $true }
			$resp = (Invoke-WebRequest @Params)
			if ($OutFile -and $cacheFile) { try { Copy-Item -LiteralPath $OutFile -Destination $cacheFile -Force } catch { } }
			return $resp
		} catch {
			$statusCode = $null
			try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
			if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and ($statusCode -notin 408, 429)) { throw }

			if ($attempt -ge $MaxRetries) { throw }
			$delay = [math]::Min(60, $RetryDelaySeconds * [math]::Pow(2, ($attempt - 1)))
			$retryAfter = $null
			try { $retryAfter = $_.Exception.Response.Headers['Retry-After'] } catch { }
			if ($retryAfter) {
				[int]$raSec = 0
				if ([int]::TryParse([string]$retryAfter, [ref]$raSec)) {
					$delay = [math]::Max($delay, $raSec)
				} else {
					try {
						$raDate = [datetime]::Parse([string]$retryAfter)
						$raDelta = [int]([math]::Ceiling(($raDate.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds))
						if ($raDelta -gt 0) { $delay = [math]::Max($delay, $raDelta) }
					} catch { }
				}
			}
			Write-Host "request failed (attempt $attempt/$MaxRetries); retrying in $delay sec: $($_.Exception.Message)"
			Start-Sleep -Seconds $delay
		}
	}
}

function Get-DockerToken($scope) {
	$resp = Invoke-TlcWebRequest -Uri "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${scope}:pull"
	return ($resp.content | ConvertFrom-Json).token
}

function Get-DockerTags([string]$repo) {
  $tags = @()
  $url = "https://hub.docker.com/v2/repositories/$repo/tags/?page_size=100"

  while ($url) {
    $resp = Invoke-TlcRestMethod -Uri $url
    $tags += $resp.results.name
    $url = $resp.next
  }

  return @{ tags = $tags }
}

function Write-TlcVars($vars) {
	$pkgRoot = Get-TlcPkgRoot
	$text = $vars | ConvertTo-Json -Depth 50 -Compress

	$rootsToReplace = @()
	try { $rootsToReplace += [System.IO.Path]::GetFullPath($pkgRoot) } catch { if ($pkgRoot) { $rootsToReplace += $pkgRoot } }
	try { $rootsToReplace += (Resolve-Path $pkgRoot -ErrorAction Stop).Path } catch { }
	$rootsToReplace = $rootsToReplace | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
	foreach ($r in $rootsToReplace) {
		$escaped = $r.Replace('\', '\\')
		$text = $text.Replace($escaped, '${.}')
	}

	$text = [regex]::Replace($text, '(?i)(?<![A-Za-z]:)\\\\pkg', '${.}')

	[IO.File]::WriteAllText((Join-Path $pkgRoot '.tlc'), $text)
}


function Set-RegistryKey($path, $name, $value) {
	if (!(Test-Path $path)) {
		New-Item -Path $path -Force | Out-Null
	}
	New-ItemProperty -Path $path -Name $name -Value $value -Force | Out-Null
}

function Find-LatestTag([object[]]$List, [string]$TagProperty, [string]$TagPattern) {
	$LatestAsset = $List[0]
	$LatestVersion = [TlcSemanticVersion]::new($LatestAsset.$TagProperty, $TagPattern)
	for ($i = 1; $i -lt $List.Count; $i += 1) {
		$version = [TlcSemanticVersion]::new($List[$i].$TagProperty, $TagPattern)
		if ($LatestVersion.CompareTo($version) -gt 0) {
			$LatestAsset = $List[$i]
			$LatestVersion = $version
		}
	}
	return @{
		Item = $LatestAsset
		Version = $LatestVersion
	}
}

function Get-GitHubRelease {
	param (
		[Parameter(Mandatory=$true)][string]$Owner,
		[Parameter(Mandatory=$true)][string]$Repo,
		[Parameter(Mandatory=$true)][string]$AssetPattern,
		[Parameter(Mandatory=$true)][string]$TagPattern
	)
	$headers = Get-TlcGitHubHeaders
	$page = 1
	$releases = @()
	do {
		$chunk = Invoke-TlcRestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases?per_page=100&page=$page" -Headers $headers
		if ($chunk) { $releases += $chunk }
		$page += 1
	} while ($chunk.Count -gt 0 -and $page -le 20)

	$filtered = @($releases | Where-Object { $_.tag_name -match $TagPattern -and -not $_.prerelease })
	if ($filtered.Count -eq 0) {
		Write-Error "Failed to find a matching GitHub Release tag for $Owner/$Repo (pattern: $TagPattern)"
		return
	}
	$Latest = Find-LatestTag $filtered 'tag_name' $TagPattern
	foreach ($Asset in $Latest.item.assets) {
		if ($Asset.name -match $AssetPattern) {
			return @{
				URL = $Asset.browser_download_url
				Name = $Asset.name
				Identifier = $Latest.item.tag_name
				Version = $Latest.version
			}
		}
	}
	Write-Error "Failed to find a GitHub Release asset for $Owner/$Repo (asset pattern: $AssetPattern)"
}

function Get-GitHubTag {
	param (
		[Parameter(Mandatory=$true)][string]$Owner,
		[Parameter(Mandatory=$true)][string]$Repo,
		[Parameter(Mandatory=$true)][string]$TagPattern
	)
	$headers = Get-TlcGitHubHeaders
	$i = 1
	$Tags = @()
	do {
		Write-Output "page=$i"
		$Page = Invoke-TlcRestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/tags?per_page=100&page=$i" -Headers $headers
		$Tags += $Page
		$i++
		if ($i -gt 200) { break }
	} while ($Page.Count -gt 0)
	$Latest = Find-LatestTag $Tags 'name' $TagPattern
	if ($Latest) {
		return @{
			Name = $Latest.item.name
			Version = $Latest.version
		}
	}
	Write-Error "Failed to find a GitHub Tag for $Owner $Repo"
}

function Install-BuildTool {
	param (
		[Parameter(Mandatory=$true)][string]$AssetName,
		[Parameter(Mandatory=$true)][string]$AssetURL,
		[string]$ToolDir = '\pkg'
	)
	$Asset = "$env:Temp\$AssetName"
	Write-Output "downloading $AssetURL to $Asset"
	Invoke-TlcWebRequest -Uri $AssetURL -OutFile $Asset
	Expand-Archive $Asset $ToolDir
}


function Get-TlcPkgRoot {
    $root = $env:TLC_PKG_ROOT
    if (-not $root) { $root = '\pkg' }

    try {
        return [System.IO.Path]::GetFullPath($root)
    } catch {
        return $root
    }
}


function Get-TlcCacheRoot {
    $root = $env:TLC_CACHE_ROOT
    if (-not $root) {
        $root = Join-Path (Get-TlcPkgRoot) 'cache'
    }
    if (-not (Test-Path $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return $root
}

function Get-TlcCachePathForUri {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Extension
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($Uri)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    if (-not $Extension) { $Extension = '' }
    if ($Extension -and (-not $Extension.StartsWith('.'))) { $Extension = '.' + $Extension }
    return (Join-Path (Get-TlcCacheRoot) ($hex + $Extension))
}

function Get-TlcPkgUri {
	$root = Get-TlcPkgRoot
	if ($IsWindows) {
		$path = $root.Replace('\\', '/')
		if ($path -match '^[A-Za-z]:/') {
			return "file:///$path"
		}
		if (-not $path.StartsWith('/')) { $path = "/$path" }
		return "file:///$path"
	}
	$path = $root.Replace('\\', '/')
	if (-not $path.StartsWith('/')) { $path = "/$path" }
	return "file://$path"
}

function Expand-TlcEnvValue {
	param(
		[AllowNull()]
		[object]$Value,

		[Parameter(Mandatory=$true)]
		[string]$PkgRoot
	)

	if ($null -eq $Value) { return $null }

	$expandOne = {
		param([string]$s)
		$out = $s.Replace('${.}', $PkgRoot)
		$out = [regex]::Replace($out, '(?i)(?<![A-Za-z]:)\\pkg', { param($m) $PkgRoot })
		return $out
	}

	if ($Value -is [string]) {
		return (& $expandOne $Value)
	}

	if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
		$out = @()
		foreach ($x in $Value) {
			if ($null -eq $x) { continue }
			if ($x -isnot [string]) { throw "env value array must contain only strings" }
			$out += (& $expandOne $x)
		}
		return $out
	}

	throw "env value must be a string or array of strings"
}

function Invoke-TlcLocalExec {
	param(
		[Parameter(Mandatory)][string]$Spec,
		[Parameter(Mandatory)][ScriptBlock]$Block
	)

	$specText = $Spec.Trim()
	$cfgName = $null
	$src = $specText
	if ($specText -match '^(.*?)<\s*(.+)$') {
		$src = $Matches[1].Trim()
		$cfgName = $Matches[2].Trim()
	}

	$pkgRoot = Get-TlcPkgRoot
	$defPath = Join-Path $pkgRoot '.tlc'
	if (-not (Test-Path -LiteralPath $defPath -PathType Leaf)) {
		throw "toolchain definition not found: $defPath"
	}

	$json = (Get-Content -LiteralPath $defPath -Raw).Trim()
	$def = $json | ConvertFrom-Json -AsHashtable
	if (-not $def.ContainsKey('env')) {
		throw "toolchain definition missing required top-level 'env' object: $defPath"
	}

	$envMap = $def['env']
	if ($cfgName) {
		if (-not $def.ContainsKey($cfgName)) {
			throw "toolchain config not found in ${defPath}: $cfgName"
		}
		$cfg = $def[$cfgName]
		if ($cfg -isnot [hashtable] -or -not $cfg.ContainsKey('env')) {
			throw "toolchain config '$cfgName' missing required 'env' object: $defPath"
		}
		$envMap = $cfg['env']
	}

	$originals = @{}
	try {
		foreach ($k in $envMap.Keys) {
			$name = [string]$k
			$orig = Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
			$originals[$name] = if ($orig) { @{ Exists = $true; Value = $orig.Value } } else { @{ Exists = $false } }

			$val = Expand-TlcEnvValue -Value $envMap[$k] -PkgRoot $pkgRoot
			if ($name -ieq 'path') {
				$sep = [System.IO.Path]::PathSeparator
				$oldPath = (Get-Item -LiteralPath 'Env:Path' -ErrorAction SilentlyContinue).Value
				if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
					$val = ($val -join $sep)
				}
				if ([string]::IsNullOrWhiteSpace([string]$val)) {
					continue
				}
				$valStr = [string]$val
				$valStr = $valStr.Trim($sep)
				$merged = if ([string]::IsNullOrWhiteSpace($oldPath)) { $valStr } else { "$valStr$sep$oldPath" }
				Set-Item -LiteralPath 'Env:Path' -Value $merged
			} else {
				if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
					$val = ($val -join [System.IO.Path]::PathSeparator)
				}
				if ($null -eq $val) {
					Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
				} else {
					Set-Item -LiteralPath "Env:$name" -Value $val
				}
			}
		}

		& $Block
	}
	finally {
		foreach ($name in $originals.Keys) {
			$info = $originals[$name]
			if ($info.Exists) {
				if ($null -eq $info.Value) {
					Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
				} else {
					Set-Item -LiteralPath "Env:$name" -Value $info.Value
				}
			} else {
				Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
			}
		}
	}
}

function Toolchain {
	[CmdletBinding()]
	param(
		[Parameter(Position=0, Mandatory)][string]$Verb,
		[Parameter(Position=1, Mandatory)][string]$Spec,
		[Parameter(Position=2, Mandatory)][ScriptBlock]$Block
	)

	if ($Verb -ne 'exec') {
		throw "Toolchains wrapper only supports: Toolchain exec <spec> { ... }"
	}

	Invoke-TlcLocalExec -Spec $Spec -Block $Block
}



function Test-TlcToolchainDefinition {
	param(
		[Parameter(Mandatory)][object]$Definition,
		[string]$Context = 'definition'
	)

	if ($null -eq $Definition) { throw "$Context is null" }

	if ($Definition -is [PSCustomObject]) {
		$Definition = $Definition | ConvertTo-Json -Depth 50 | ConvertFrom-Json
	}

	$envProp = $Definition.PSObject.Properties['env']
	if (-not $envProp) { throw "$Context missing required top-level 'env' object" }
	$envObj = $envProp.Value
	Test-TlcEnvMap -EnvMap $envObj -Context "$Context.env" | Out-Null

	foreach ($p in $Definition.PSObject.Properties) {
		if ($p.Name -eq 'env') { continue }
		if ($null -eq $p.Value) { continue }
		$cfg = $p.Value
		$cfgEnv = $cfg.PSObject.Properties['env']
		if (-not $cfgEnv) { throw "$Context.$($p.Name) missing required 'env' object" }
		Test-TlcEnvMap -EnvMap $cfgEnv.Value -Context "$Context.$($p.Name).env" | Out-Null
	}

	return $true
}

function Test-TlcEnvMap {
	param(
		[Parameter(Mandatory)][object]$EnvMap,
		[string]$Context = 'env'
	)
	if ($EnvMap -isnot [PSCustomObject] -and $EnvMap -isnot [hashtable]) {
		throw "$Context must be an object/map"
	}
	$props = if ($EnvMap -is [hashtable]) { $EnvMap.Keys | ForEach-Object { @{ Name = $_; Value = $EnvMap[$_] } } } else { $EnvMap.PSObject.Properties }
	foreach ($p in $props) {
		$name = $p.Name
		$val = $p.Value
		if ($null -eq $val) { continue }
		if ($val -is [string]) { continue }
		if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
			foreach ($x in $val) {
				if ($null -eq $x) { continue }
				if ($x -isnot [string]) { throw "$Context.$name must contain only strings" }
			}
			continue
		}
		throw "$Context.$name must be a string or array of strings"
	}
	return $true
}

function Get-TlcDefinitionJson {
	$pkgRoot = Get-TlcPkgRoot
	$defPath = Join-Path $pkgRoot '.tlc'
	if (-not (Test-Path -LiteralPath $defPath -PathType Leaf)) {
		throw "toolchain definition not found: $defPath"
	}
	return (Get-Content -LiteralPath $defPath -Raw).Trim()
}

function Assert-TlcDefinitionFile {
	$pkgRoot = Get-TlcPkgRoot
	$defPath = Join-Path $pkgRoot '.tlc'
	if (-not (Test-Path -LiteralPath $defPath -PathType Leaf)) {
		throw "toolchain definition not found: $defPath"
	}
	$json = (Get-Content -LiteralPath $defPath -Raw).Trim()
	$def = $json | ConvertFrom-Json
	Test-TlcToolchainDefinition -Definition $def -Context $defPath | Out-Null
	return $json
}

