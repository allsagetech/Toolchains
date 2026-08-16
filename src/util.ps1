<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

. "$PSScriptRoot\network.ps1"
. "$PSScriptRoot\integrity.ps1"
. "$PSScriptRoot\huggingface-download.ps1"
. "$PSScriptRoot\huggingface-image.ps1"

function Get-TlcApplicationPath {
	param(
		[Parameter(Mandatory=$true)][string]$Name
	)

	$command = @(Get-Command $Name -CommandType Application -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Source) }) | Select-Object -First 1
	if (-not $command) { throw "Could not resolve application: $Name" }
	return [string]$command.Source
}

function Invoke-TlcVerifiedGoCommandBuild {
	param(
		[Parameter(Mandatory=$true)][string]$Module,
		[Parameter(Mandatory=$true)][string]$Version,
		[Parameter(Mandatory=$true)][string]$Command,
		[Parameter(Mandatory=$true)][string]$OutputPath,
		[hashtable]$MinimumModules = @{},
		[string]$GoToolchain = 'go1.26.6',
		[string]$BuildTags,
		[string]$LdFlags
	)

	$buildRoot = Join-Path ([IO.Path]::GetTempPath()) "tlc-go-command-$([guid]::NewGuid().ToString('n'))"
	$locationPushed = $false
	$previous = @{
		CGO_ENABLED = $env:CGO_ENABLED
		GOFLAGS = $env:GOFLAGS
		GOSUMDB = $env:GOSUMDB
		GOTOOLCHAIN = $env:GOTOOLCHAIN
		GOWORK = $env:GOWORK
	}
	try {
		New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
		$outputParent = Split-Path -Parent $OutputPath
		if ($outputParent) { New-Item -ItemType Directory -Path $outputParent -Force | Out-Null }

		$env:CGO_ENABLED = '0'
		$env:GOFLAGS = '-mod=mod'
		$env:GOSUMDB = 'sum.golang.org'
		$env:GOTOOLCHAIN = $GoToolchain
		$env:GOWORK = 'off'
		$go = Get-TlcApplicationPath -Name 'go'

		Push-Location $buildRoot
		$locationPushed = $true
		& $go mod init "toolchains.local/patched-$([guid]::NewGuid().ToString('n'))"
		if ($LASTEXITCODE -ne 0) { throw "Go module initialization failed with exit code $LASTEXITCODE" }

		$requirements = @("$Module@$Version")
		foreach ($requiredModule in ($MinimumModules.Keys | Sort-Object)) {
			$requirements += "$requiredModule@$($MinimumModules[$requiredModule])"
		}
		& $go get @requirements
		if ($LASTEXITCODE -ne 0) { throw "verified Go source resolution failed with exit code $LASTEXITCODE" }

		foreach ($requiredModule in ($MinimumModules.Keys | Sort-Object)) {
			$minimumVersion = [string]$MinimumModules[$requiredModule]
			$resolvedVersion = (& $go list -m -f '{{.Version}}' $requiredModule | Out-String).Trim()
			if ($LASTEXITCODE -ne 0 -or $resolvedVersion -notmatch '^v?([0-9]+)\.([0-9]+)\.([0-9]+)$' -or $minimumVersion -notmatch '^v?([0-9]+)\.([0-9]+)\.([0-9]+)$') {
				throw "could not verify resolved Go module version for $requiredModule"
			}
			$resolvedSemanticVersion = [TlcSemanticVersion]::new($resolvedVersion.TrimStart('v'))
			$minimumSemanticVersion = [TlcSemanticVersion]::new($minimumVersion.TrimStart('v'))
			if (-not $resolvedSemanticVersion.Equals($minimumSemanticVersion) -and -not $resolvedSemanticVersion.LaterThan($minimumSemanticVersion)) {
				throw "$requiredModule resolved to $resolvedVersion, below required version $minimumVersion"
			}
		}

		$buildArguments = @('build', '-trimpath')
		if (-not [string]::IsNullOrWhiteSpace($BuildTags)) { $buildArguments += @('-tags', $BuildTags) }
		if (-not [string]::IsNullOrWhiteSpace($LdFlags)) { $buildArguments += @('-ldflags', $LdFlags) }
		$buildArguments += @('-o', $OutputPath, $Command)
		& $go @buildArguments
		if ($LASTEXITCODE -ne 0) { throw "verified Go command build failed with exit code $LASTEXITCODE" }
		if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { throw "Go command build did not produce $OutputPath" }
	} finally {
		if ($locationPushed) { Pop-Location }
		foreach ($name in $previous.Keys) {
			if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue }
			else { Set-Item -LiteralPath "env:$name" -Value $previous[$name] }
		}
		if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
	}
}

function Write-TlcVars($vars) {
	$pkgRoot = Get-TlcPkgRoot
	$text = $vars | ConvertTo-Json -Depth 50 -Compress

	$rootsToReplace = @()
	try { $rootsToReplace += [System.IO.Path]::GetFullPath($pkgRoot) } catch { if ($pkgRoot) { $rootsToReplace += $pkgRoot } }
	try { $rootsToReplace += (Resolve-Path $pkgRoot -ErrorAction Stop).Path } catch { Write-Debug "Package root cannot be resolved yet: $($_.Exception.Message)" }
	$rootsToReplace = $rootsToReplace | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
	foreach ($r in $rootsToReplace) {
		$escaped = $r.Replace('\', '\\')
		$text = $text.Replace($escaped, '${.}')
	}

	$text = [regex]::Replace($text, '(?i)(?<![A-Za-z]:)\\\\pkg', '${.}')

	if (-not (Test-Path -LiteralPath $pkgRoot -PathType Container)) {
		New-Item -ItemType Directory -Path $pkgRoot -Force | Out-Null
	}

	[IO.File]::WriteAllText((Join-Path $pkgRoot '.tlc'), $text)
}

function Set-RegistryKey($path, $name, $value) {
	if (!(Test-Path $path)) {
		New-Item -Path $path -Force | Out-Null
	}
	New-ItemProperty -Path $path -Name $name -Value $value -Force | Out-Null
}

function Find-LatestTag([object[]]$List, [string]$TagProperty, [string]$TagPattern) {
	$matching = @($List | Where-Object { $_ -and [string]$_.$TagProperty -match $TagPattern })
	if ($matching.Count -eq 0) { return $null }
	$LatestAsset = $matching[0]
	$LatestVersion = [TlcSemanticVersion]::new($LatestAsset.$TagProperty, $TagPattern)
	for ($i = 1; $i -lt $matching.Count; $i += 1) {
		$version = [TlcSemanticVersion]::new($matching[$i].$TagProperty, $TagPattern)
		if ($LatestVersion.CompareTo($version) -gt 0) {
			$LatestAsset = $matching[$i]
			$LatestVersion = $version
		}
	}
	return @{
		Item = $LatestAsset
		Version = $LatestVersion
	}
}

function Select-TlcGitHubReleaseAsset {
	param (
		[Parameter(Mandatory=$true)][object[]]$Releases,
		[Parameter(Mandatory=$true)][string]$AssetPattern,
		[Parameter(Mandatory=$true)][string]$TagPattern
	)

	$eligible = @()
	foreach ($release in @($Releases)) {
		if (-not $release -or [bool]$release.prerelease -or [string]$release.tag_name -notmatch $TagPattern) { continue }
		$asset = @($release.assets | Where-Object { [string]$_.name -match $AssetPattern }) | Select-Object -First 1
		if (-not $asset) { continue }
		$eligible += [pscustomobject]@{
			tag_name = [string]$release.tag_name
			Release = $release
			Asset = $asset
		}
	}
	if ($eligible.Count -eq 0) { return $null }

	$latest = Find-LatestTag $eligible 'tag_name' $TagPattern
	return @{
		Release = $latest.Item.Release
		Asset = $latest.Item.Asset
		Version = $latest.Version
	}
}

function ConvertTo-TlcGitHubReleaseAssetResult {
	param([Parameter(Mandatory=$true)][hashtable]$Selection)

	$asset = $Selection.Asset
	$assetSha256 = $null
	$assetDigest = [string]$asset.digest
	if ($assetDigest -match '^sha256:([0-9a-fA-F]{64})$') {
		$assetSha256 = $Matches[1].ToLowerInvariant()
		$script:TlcKnownAssetSha256[[string]$asset.browser_download_url] = $assetSha256
	}
	return @{
		URL = $asset.browser_download_url
		Name = $asset.name
		ExpectedSha256 = $assetSha256
		Identifier = $Selection.Release.tag_name
		Version = $Selection.Version
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

	# Most repositories can be resolved from the small, stable latest-release
	# endpoint. This avoids downloading enormous release histories such as the
	# Adoptium repositories, whose releases can contain hundreds of assets.
	try {
		$latestRelease = Invoke-TlcRestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases/latest" -Headers $headers
		$selection = Select-TlcGitHubReleaseAsset -Releases @($latestRelease) -AssetPattern $AssetPattern -TagPattern $TagPattern
		if ($selection) { return ConvertTo-TlcGitHubReleaseAssetResult -Selection $selection }
	} catch {
		Write-Verbose "Latest-release lookup failed for ${Owner}/${Repo}; falling back to paginated releases: $($_.Exception.Message)"
	}

	# A repository's newest release may intentionally have no artifacts yet.
	# Search smaller pages and select only releases that actually contain the
	# requested asset, so an empty newest release cannot hide the prior usable one.
	$page = 1
	$matchingTagSeen = $false
	do {
		$chunk = @(Invoke-TlcRestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases?per_page=20&page=$page" -Headers $headers)
		if (@($chunk | Where-Object { -not $_.prerelease -and [string]$_.tag_name -match $TagPattern }).Count -gt 0) {
			$matchingTagSeen = $true
		}
		$selection = Select-TlcGitHubReleaseAsset -Releases $chunk -AssetPattern $AssetPattern -TagPattern $TagPattern
		if ($selection) { return ConvertTo-TlcGitHubReleaseAssetResult -Selection $selection }
		$page += 1
	} while ($chunk.Count -gt 0 -and $page -le 20)

	if ($matchingTagSeen) {
		Write-Error "Failed to find a GitHub Release asset for $Owner/$Repo (asset pattern: $AssetPattern)"
	} else {
		Write-Error "Failed to find a matching GitHub Release tag for $Owner/$Repo (pattern: $TagPattern)"
	}
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
		[string]$ToolDir,
		[string]$ExpectedSha256,
		[string]$ExpectedHash,
		[ValidateSet('SHA256', 'SHA384', 'SHA512')][string]$ExpectedHashAlgorithm = 'SHA256',
		[switch]$RequireValidAuthenticodeSignature,
		[scriptblock]$SignatureVerifier
	)
	if (-not $ToolDir) { $ToolDir = Get-TlcPkgRoot }
	if (-not $ExpectedSha256 -and -not $ExpectedHash -and $script:TlcKnownAssetSha256.ContainsKey($AssetURL)) {
		$ExpectedSha256 = [string]$script:TlcKnownAssetSha256[$AssetURL]
	}
	if (-not $ExpectedSha256 -and -not $ExpectedHash -and $AssetURL -match '^https://nodejs\.org/dist/([^/]+)/([^/?#]+)$') {
		$ExpectedSha256 = Get-TlcRemoteSha256 -ChecksumUri "https://nodejs.org/dist/$($Matches[1])/SHASUMS256.txt" -AssetName $Matches[2]
	}
	$Asset = "$env:Temp\$AssetName"
	Write-Output "downloading $AssetURL to $Asset"
	Invoke-TlcWebRequest -Uri $AssetURL -OutFile $Asset -ExpectedSha256 $ExpectedSha256 -ExpectedHash $ExpectedHash -ExpectedHashAlgorithm $ExpectedHashAlgorithm -RequireValidAuthenticodeSignature:$RequireValidAuthenticodeSignature -SignatureVerifier $SignatureVerifier
	Expand-Archive $Asset $ToolDir
}

function Get-DotNetReleaseAsset {
	param(
		[Parameter(Mandatory=$true)][ValidateSet('sdk', 'runtime')][string]$Product,
		[string]$Rid = 'win-x64',
		[string]$Extension = '.zip',
		[switch]$IncludePreview
	)

	$index = Invoke-TlcRestMethod -Uri 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json'
	$channels = @($index.'releases-index') | Where-Object {
		$phase = [string]$_.'support-phase'
		($phase -ne 'eol') -and ($IncludePreview -or $phase -ne 'preview')
	} | Sort-Object -Property @{
		Expression = {
			$parts = ([string]$_.'channel-version').Split('.')
			[version]::new([int]$parts[0], [int]$parts[1], 0)
		}
		Descending = $true
	}

	foreach ($channel in $channels) {
		$releaseData = Invoke-TlcRestMethod -Uri ([string]$channel.'releases.json')
		$releases = @($releaseData.releases) | Sort-Object -Property @{
			Expression = {
				try { [datetime]::Parse([string]$_.'release-date') } catch { [datetime]::MinValue }
			}
			Descending = $true
		}

		foreach ($release in $releases) {
			$assets = @()
			if ($Product -eq 'sdk') {
				if ($release.sdk) { $assets += $release.sdk }
				if ($release.sdks) { $assets += @($release.sdks) }
			} else {
				if ($release.runtime) { $assets += $release.runtime }
			}

			foreach ($asset in $assets) {
				$version = [string]$asset.version
				if ([string]::IsNullOrWhiteSpace($version)) { continue }
				if ((-not $IncludePreview) -and $version.Contains('-')) { continue }

				$file = @($asset.files) | Where-Object {
					([string]$_.rid) -eq $Rid -and
					([string]$_.url) -and
					([string]$_.url).EndsWith($Extension, [System.StringComparison]::OrdinalIgnoreCase)
				} | Select-Object -First 1
				if (-not $file) { continue }

				$name = [string]$file.name
				if ([string]::IsNullOrWhiteSpace($name)) {
					try { $name = [IO.Path]::GetFileName(([Uri][string]$file.url).AbsolutePath) } catch { Write-Debug "Could not derive artifact name from URL: $($_.Exception.Message)" }
				}
				if ([string]::IsNullOrWhiteSpace($name)) {
					$name = "dotnet-$Product-$version-$Rid$Extension"
				}

				return @{
					Name = $name
					URL = [string]$file.url
					Hash = [string]$file.hash
					HashAlgorithm = 'SHA512'
					Version = [TlcSemanticVersion]::new($version)
					VersionText = $version
					ChannelVersion = [string]$channel.'channel-version'
					ReleaseDate = [string]$release.'release-date'
				}
			}
		}
	}

	throw "Failed to find a .NET $Product $Rid$Extension release asset from official release metadata."
}


. "$PSScriptRoot\cache.ps1"
. "$PSScriptRoot\local-exec.ps1"

. "$PSScriptRoot\definition-file.ps1"

