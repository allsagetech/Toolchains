<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function Expand-TlcVerifiedTarGzArchive {
	param(
		[Parameter(Mandatory=$true)][string]$Path,
		[Parameter(Mandatory=$true)][string]$Destination
	)

	$tar = Get-TlcApplicationPath -Name 'tar'
	$entries = @(& $tar '-tzf' $Path)
	if ($LASTEXITCODE -ne 0 -or $entries.Count -eq 0) { throw "Could not list verified archive $Path." }
	foreach ($entry in $entries) {
		$normalized = ([string]$entry).Replace('\', '/')
		$segments = @($normalized.Split('/') | Where-Object { $_ -and $_ -ne '.' })
		if ($segments -contains '..' -or $normalized.StartsWith('/') -or $normalized.Contains(':') -or $normalized.IndexOf([char]0) -ge 0) {
			throw "verified archive contains an unsafe path: $entry"
		}
	}

	$details = @(& $tar '-tvzf' $Path)
	if ($LASTEXITCODE -ne 0) { throw "Could not inspect verified archive $Path." }
	if (@($details | Where-Object { $_.TrimStart() -match '^[lh]' }).Count -gt 0) {
		throw "verified archive contains links, which are not permitted: $Path"
	}

	if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
	New-Item -ItemType Directory -Path $Destination -Force | Out-Null
	& $tar '-xzf' $Path '-C' $Destination
	if ($LASTEXITCODE -ne 0) { throw "Could not extract verified archive $Path." }
}

function Install-TlcPinnedNpmArchive {
	param(
		[Parameter(Mandatory=$true)][ValidatePattern('^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$')][string]$Name,
		[Parameter(Mandatory=$true)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')][string]$Version,
		[Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{128}$')][string]$ExpectedSha512,
		[Parameter(Mandatory=$true)][string]$Destination
	)

	$encodedName = [uri]::EscapeDataString($Name)
	$archivePackageName = @($Name -split '/')[-1]
	$archiveBaseName = "$($Name.Replace('@', '').Replace('/', '-'))-$Version"
	$archiveName = "$archivePackageName-$Version.tgz"
	$archiveUri = "https://registry.npmjs.org/$encodedName/-/$archiveName"
	$archivePath = Get-TlcStagingPath $archiveName
	$extractRoot = Get-TlcStagingPath "$archiveBaseName-extract"
	$packageRoot = [IO.Path]::GetFullPath((Get-TlcPkgRoot)).TrimEnd('\', '/')
	$packagePrefix = $packageRoot + [IO.Path]::DirectorySeparatorChar
	$destinationPath = [IO.Path]::GetFullPath($Destination)
	if (-not $destinationPath.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
		throw "Refusing to install npm archive outside package root: $destinationPath"
	}

	try {
		if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
		New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
		Invoke-TlcWebRequest -Uri $archiveUri -OutFile $archivePath -ExpectedHash $ExpectedSha512 -ExpectedHashAlgorithm SHA512 | Out-Null

		$tar = Get-TlcApplicationPath -Name 'tar'
		$entries = @(& $tar '-tzf' $archivePath)
		if ($LASTEXITCODE -ne 0 -or $entries.Count -eq 0) { throw "Could not list verified npm archive $archiveName." }
		foreach ($entry in $entries) {
			$normalized = ([string]$entry).Replace('\', '/')
			$segments = @($normalized.Split('/') | Where-Object { $_ })
			if (($normalized -ne 'package') -and (-not $normalized.StartsWith('package/', [StringComparison]::Ordinal))) {
				throw "npm archive $archiveName contains a path outside package/: $entry"
			}
			if ($segments -contains '..' -or $normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:' -or $normalized.IndexOf([char]0) -ge 0) {
				throw "npm archive $archiveName contains an unsafe path: $entry"
			}
		}
		$details = @(& $tar '-tvzf' $archivePath)
		if ($LASTEXITCODE -ne 0) { throw "Could not inspect verified npm archive $archiveName." }
		if (@($details | Where-Object { $_.TrimStart() -match '^[lh]' }).Count -gt 0) {
			throw "npm archive $archiveName contains links, which are not permitted."
		}

		& $tar '-xzf' $archivePath '-C' $extractRoot
		if ($LASTEXITCODE -ne 0) { throw "Could not extract verified npm archive $archiveName." }
		$source = Join-Path $extractRoot 'package'
		$manifestPath = Join-Path $source 'package.json'
		if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "npm archive $archiveName has no package manifest." }
		$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
		if ([string]$manifest.name -cne $Name -or [string]$manifest.version -cne $Version) {
			throw "npm archive identity mismatch: expected $Name@$Version, got $($manifest.name)@$($manifest.version)."
		}
		if (Test-Path -LiteralPath $destinationPath) { Remove-Item -LiteralPath $destinationPath -Recurse -Force }
		New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
		Move-Item -LiteralPath $source -Destination $destinationPath
	} finally {
		Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
	}
}

function Initialize-TlcNodePackage {
	param(
		[Parameter(Mandatory=$true)][int]$Major,
		[string]$LifecycleNote,
		[ValidateRange(0, 999)][int]$BuildRevision = 0,
		[string]$NpmVersion,
		[ValidatePattern('^$|^[0-9a-fA-F]{128}$')][string]$NpmExpectedSha512,
		[hashtable]$NpmDependencyOverlays = @{}
	)
	if ([bool]$NpmVersion -xor [bool]$NpmExpectedSha512) {
		throw 'NpmVersion and NpmExpectedSha512 must be provided together.'
	}

	$global:TlcPackageConfig = @{
		Name = 'node'
		Matcher = "^node-$Major\."
		FamilyMajor = $Major
		LifecycleNote = $LifecycleNote
		BuildRevision = $BuildRevision
		NpmVersion = $NpmVersion
		NpmExpectedSha512 = $NpmExpectedSha512
		NpmDependencyOverlays = $NpmDependencyOverlays
	}

	function global:Install-TlcPackage {
		$major = [int]$TlcPackageConfig.FamilyMajor
		$latest = Get-GitHubTag -Owner 'nodejs' -Repo 'node' -TagPattern "^v($major)\.([0-9]+)\.([0-9]+)$"
		$upstreamVersion = $latest.Version.ToString()
		$packageVersion = if ([int]$TlcPackageConfig.BuildRevision -gt 0) { "$upstreamVersion+$($TlcPackageConfig.BuildRevision)" } else { $upstreamVersion }
		$packageSemanticVersion = [TlcSemanticVersion]::new($packageVersion)
		$TlcPackageConfig.UpToDate = -not $packageSemanticVersion.LaterThan($TlcPackageConfig.Latest)
		$TlcPackageConfig.Version = $packageVersion
		if ($TlcPackageConfig.UpToDate) { return }

		$tag = $latest.name
		$assetName = "node-$tag-win-x64.zip"
		Install-BuildTool -AssetName $assetName -AssetURL "https://nodejs.org/dist/$tag/$assetName"
		$nodeExecutable = Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'node.exe' | Select-Object -First 1
		if (-not $nodeExecutable) { throw "$assetName did not contain node.exe." }
		$nodeRoot = $nodeExecutable.DirectoryName
		if ($TlcPackageConfig.NpmVersion) {
			$npmRoot = Join-Path $nodeRoot 'node_modules\npm'
			Install-TlcPinnedNpmArchive -Name 'npm' -Version $TlcPackageConfig.NpmVersion `
				-ExpectedSha512 $TlcPackageConfig.NpmExpectedSha512 -Destination $npmRoot
			foreach ($dependencyName in @($TlcPackageConfig.NpmDependencyOverlays.Keys | Sort-Object)) {
				$overlay = $TlcPackageConfig.NpmDependencyOverlays[$dependencyName]
				Install-TlcPinnedNpmArchive -Name $dependencyName -Version $overlay.Version `
					-ExpectedSha512 $overlay.ExpectedSha512 -Destination (Join-Path $npmRoot "node_modules\$dependencyName")
			}
		}
		Write-TlcVars @{
			env = @{
				path = $nodeRoot
			}
		}
	}

	function global:Test-TlcPackageInstall {
		if ($TlcPackageConfig.NpmVersion) {
			Toolchain exec (Get-TlcPkgUri) { node --version; npm --version; npx --version }
		} else {
			Toolchain exec (Get-TlcPkgUri) { node --version }
		}
	}
}

function Initialize-TlcAdoptiumPackage {
	param(
		[Parameter(Mandatory=$true)][ValidateSet('jdk','jre')][string]$Kind,
		[Parameter(Mandatory=$true)][int]$Major,
		[switch]$IncludeX86
	)

	$global:TlcPackageConfig = @{
		Name = $Kind
		Matcher = "^$Kind-$Major\."
		FamilyKind = $Kind
		FamilyMajor = $Major
		FamilyIncludeX86 = [bool]$IncludeX86
	}

	function global:Install-TlcPackage {
		$kind = [string]$TlcPackageConfig.FamilyKind
		$major = [int]$TlcPackageConfig.FamilyMajor
		$includeX86 = [bool]$TlcPackageConfig.FamilyIncludeX86
		$tagPattern = if ($major -eq 8) { '^jdk(8)u()([0-9]+)-b([0-9]+)$' } else { "^jdk-($major)\.([0-9]+)\.([0-9]+)((\.[0-9]+)?(\+[0-9]+)?)$" }
		$asset = Get-GitHubRelease `
			-Owner 'adoptium' `
			-Repo "temurin$major-binaries" `
			-AssetPattern "^.*${kind}_x64_windows_hotspot_.+?\.zip$" `
			-TagPattern $tagPattern
		$TlcPackageConfig.UpToDate = -not $asset.Version.LaterThan($TlcPackageConfig.Latest)
		$TlcPackageConfig.Version = $asset.Version.ToString()
		if ($TlcPackageConfig.UpToDate) { return }

		Install-BuildTool -AssetName $asset.Name -AssetURL $asset.URL -ToolDir (Get-TlcStagingPath 'pkg-preinstall\x64')
		New-Item -Path (Get-TlcPkgPath 'x64') -ItemType Directory -Force -ErrorAction Ignore | Out-Null
		Move-Item "$(Get-ChildItem -Path (Get-TlcStagingPath 'pkg-preinstall\x64') -Recurse -Include 'bin' | Select-Object -First 1 | ForEach-Object { Split-Path $_ })\*" (Get-TlcPkgPath 'x64')

		$haveX86 = $false
		if ($includeX86) {
			try {
				Install-BuildTool `
					-AssetName $asset.Name.Replace('_x64_', '_x86-32_') `
					-AssetURL $asset.URL.Replace('_x64_', '_x86-32_') `
					-ToolDir (Get-TlcStagingPath 'pkg-preinstall\x86')
				New-Item -Path (Get-TlcPkgPath 'x86') -ItemType Directory -Force -ErrorAction Ignore | Out-Null
				Move-Item "$(Get-ChildItem -Path (Get-TlcStagingPath 'pkg-preinstall\x86') -Recurse -Include 'bin' | Select-Object -First 1 | ForEach-Object { Split-Path $_ })\*" (Get-TlcPkgPath 'x86')
				$haveX86 = $true
			} catch {
				if ($_ -match 'Not Found|no upstream hash') {
					Write-Host "x86-32 $($kind.ToUpperInvariant()) asset not published for this release; skipping x86 variant."
				} else {
					throw
				}
			}
		}

		$x64Bin = (Get-ChildItem -Path (Get-TlcPkgPath 'x64') -Recurse -Include 'java.exe' | Select-Object -First 1).DirectoryName
		$x64Home = Split-Path $x64Bin -Parent
		$vars = @{
			env = @{ java_home = $x64Home; path = $x64Bin }
			amd64 = @{ env = @{ java_home = $x64Home; path = $x64Bin } }
			x64 = @{ env = @{ java_home = $x64Home; path = $x64Bin } }
		}
		if ($haveX86) {
			$x86Bin = (Get-ChildItem -Path (Get-TlcPkgPath 'x86') -Recurse -Include 'java.exe' | Select-Object -First 1).DirectoryName
			$vars['x86'] = @{ env = @{ java_home = (Split-Path $x86Bin -Parent); path = $x86Bin } }
		}
		Write-TlcVars $vars
	}

	function global:Test-TlcPackageInstall {
		$kind = [string]$TlcPackageConfig.FamilyKind
		if ($kind -eq 'jdk') {
			Toolchain exec (Get-TlcPkgUri) { java -version; javac -version }
		} else {
			Toolchain exec (Get-TlcPkgUri) { java -version }
		}
		if (Test-Path (Get-TlcPkgPath 'x86')) {
			if ($kind -eq 'jdk') {
				Toolchain exec "$(Get-TlcPkgUri)<x86" { java -version; javac -version }
			} else {
				Toolchain exec "$(Get-TlcPkgUri)<x86" { java -version }
			}
		}
	}
}

function Initialize-TlcK9sPackage {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[switch]$Linux
	)

	$global:TlcPackageConfig = @{
		Name = $Name
		CanonicalName = 'k9s'
		Platform = if ($Linux) { 'linux/amd64' } else { 'windows/amd64' }
		BuildRevision = 1
		GoToolchain = 'go1.26.6'
		UpstreamVersion = '0.51.0'
		UpstreamCommit = '558caafe7ba067467de46b320cc22ef11fef9c34'
		UpstreamDate = '2026-06-06T05:22:55Z'
		PatchedContainerdVersion = 'v1.7.33'
		PatchedContainerdV2Version = 'v2.2.5'
		PatchedGoGitVersion = 'v5.19.2'
		PatchedCryptoVersion = 'v0.53.0'
		PatchedNetVersion = 'v0.56.0'
		PatchedTextVersion = 'v0.39.0'
		PatchedGrpcVersion = 'v1.82.1'
		PatchedOrasVersion = 'v2.6.2'
		IsLinux = [bool]$Linux
	}
	if ($Linux) { $global:TlcPackageConfig.RunsOn = 'ubuntu-22.04' }

	function global:Install-TlcPackage {
		$packageVersion = [TlcSemanticVersion]::new("$($TlcPackageConfig.UpstreamVersion)+$($TlcPackageConfig.BuildRevision)")
		$TlcPackageConfig.Version = $packageVersion.ToString()
		$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
		if ($TlcPackageConfig.UpToDate) { return }

		$pkgRoot = Get-TlcPkgRoot
		New-Item -Path $pkgRoot -ItemType Directory -Force -ErrorAction Ignore | Out-Null
		$outputName = if ($TlcPackageConfig.IsLinux) { 'k9s' } else { 'k9s.exe' }
		$executable = Get-TlcPkgPath $outputName
		$minimumModules = @{
			'github.com/containerd/containerd' = $TlcPackageConfig.PatchedContainerdVersion
			'github.com/containerd/containerd/v2' = $TlcPackageConfig.PatchedContainerdV2Version
			'github.com/go-git/go-git/v5' = $TlcPackageConfig.PatchedGoGitVersion
			'golang.org/x/crypto' = $TlcPackageConfig.PatchedCryptoVersion
			'golang.org/x/net' = $TlcPackageConfig.PatchedNetVersion
			'golang.org/x/text' = $TlcPackageConfig.PatchedTextVersion
			'google.golang.org/grpc' = $TlcPackageConfig.PatchedGrpcVersion
			'oras.land/oras-go/v2' = $TlcPackageConfig.PatchedOrasVersion
		}
		$ldflags = "-s -w -X github.com/derailed/k9s/cmd.version=v$($TlcPackageConfig.UpstreamVersion) -X github.com/derailed/k9s/cmd.commit=$($TlcPackageConfig.UpstreamCommit) -X github.com/derailed/k9s/cmd.date=$($TlcPackageConfig.UpstreamDate)"
		Invoke-TlcVerifiedGoCommandBuild `
			-Module 'github.com/derailed/k9s' `
			-Version "v$($TlcPackageConfig.UpstreamVersion)" `
			-Command 'github.com/derailed/k9s' `
			-OutputPath $executable `
			-MinimumModules $minimumModules `
			-GoToolchain $TlcPackageConfig.GoToolchain `
			-LdFlags $ldflags

		if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "patched K9s source build did not produce $outputName" }
		if ($TlcPackageConfig.IsLinux) {
			& chmod '+x' $executable
			if ($LASTEXITCODE -ne 0) { throw 'failed to mark k9s executable' }
		}
		Write-TlcVars @{ env = @{ path = $pkgRoot } }
	}

	function global:Test-TlcPackageInstall {
		Toolchain exec (Get-TlcPkgUri) {
			k9s version
		}
	}
}

function Initialize-TlcCosignPackage {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[switch]$Linux
	)

	$global:TlcPackageConfig = @{
		Name = $Name
		CanonicalName = 'cosign'
		Platform = if ($Linux) { 'linux/amd64' } else { 'windows/amd64' }
		Upstream = 'https://github.com/sigstore/cosign'
		BuildRevision = 1
		GoToolchain = 'go1.26.6'
		PatchedTextVersion = 'v0.39.0'
		PatchedGrpcVersion = 'v1.82.1'
		IsLinux = [bool]$Linux
	}
	if ($Linux) { $global:TlcPackageConfig.RunsOn = 'ubuntu-22.04' }

	function global:Install-TlcPackage {
		$latest = Get-GitHubTag -Owner 'sigstore' -Repo 'cosign' -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
		$upstreamVersion = $latest.Version.ToString()
		$packageVersion = [TlcSemanticVersion]::new("$upstreamVersion+$($TlcPackageConfig.BuildRevision)")
		$TlcPackageConfig.Version = $packageVersion.ToString()
		$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
		if ($TlcPackageConfig.UpToDate) { return }

		$outputName = if ($TlcPackageConfig.IsLinux) { 'cosign' } else { 'cosign.exe' }
		$executable = Get-TlcPkgPath $outputName
		$ldflags = "-buildid= -s -w -X sigs.k8s.io/release-utils/version.gitVersion=$($latest.Name) -X sigs.k8s.io/release-utils/version.gitTreeState=clean"
		Invoke-TlcVerifiedGoCommandBuild `
			-Module 'github.com/sigstore/cosign/v3' `
			-Version ([string]$latest.Name) `
			-Command 'github.com/sigstore/cosign/v3/cmd/cosign' `
			-OutputPath $executable `
			-MinimumModules @{
				'golang.org/x/text' = $TlcPackageConfig.PatchedTextVersion
				'google.golang.org/grpc' = $TlcPackageConfig.PatchedGrpcVersion
			} `
			-GoToolchain $TlcPackageConfig.GoToolchain `
			-LdFlags $ldflags

		if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "patched Cosign source build did not produce $outputName" }
		if ($TlcPackageConfig.IsLinux) {
			& chmod '+x' $executable
			if ($LASTEXITCODE -ne 0) { throw 'failed to mark cosign executable' }
		}
		Write-TlcVars @{ env = @{ path = Get-TlcPkgRoot } }
	}

	function global:Test-TlcPackageInstall {
		Toolchain exec (Get-TlcPkgUri) {
			cosign version
		}
	}
}

function Initialize-TlcCranePackage {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[switch]$Linux
	)

	$global:TlcPackageConfig = @{
		Name = $Name
		CanonicalName = 'crane'
		Platform = if ($Linux) { 'linux/amd64' } else { 'windows/amd64' }
		Upstream = 'https://github.com/google/go-containerregistry'
		BuildRevision = 1
		GoToolchain = 'go1.26.6'
		IsLinux = [bool]$Linux
	}
	if ($Linux) { $global:TlcPackageConfig.RunsOn = 'ubuntu-22.04' }

	function global:Install-TlcPackage {
		$latest = Get-GitHubTag -Owner 'google' -Repo 'go-containerregistry' -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
		$upstreamVersion = $latest.Version.ToString()
		$packageVersion = [TlcSemanticVersion]::new("$upstreamVersion+$($TlcPackageConfig.BuildRevision)")
		$TlcPackageConfig.Version = $packageVersion.ToString()
		$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
		if ($TlcPackageConfig.UpToDate) { return }

		$outputName = if ($TlcPackageConfig.IsLinux) { 'crane' } else { 'crane.exe' }
		$executable = Get-TlcPkgPath $outputName
		$ldflags = "-s -w -X github.com/google/go-containerregistry/cmd/crane/cmd.Version=$upstreamVersion -X github.com/google/go-containerregistry/pkg/v1/remote/transport.Version=$upstreamVersion"
		Invoke-TlcVerifiedGoCommandBuild `
			-Module 'github.com/google/go-containerregistry' `
			-Version ([string]$latest.Name) `
			-Command 'github.com/google/go-containerregistry/cmd/crane' `
			-OutputPath $executable `
			-GoToolchain $TlcPackageConfig.GoToolchain `
			-LdFlags $ldflags

		if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "patched Crane source build did not produce $outputName" }
		if ($TlcPackageConfig.IsLinux) {
			& chmod '+x' $executable
			if ($LASTEXITCODE -ne 0) { throw 'failed to mark crane executable' }
		}
		Write-TlcVars @{ env = @{ path = Get-TlcPkgRoot } }
	}

	function global:Test-TlcPackageInstall {
		Toolchain exec (Get-TlcPkgUri) {
			crane version
		}
	}
}

function Initialize-TlcOrasPackage {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[switch]$Linux
	)

	$global:TlcPackageConfig = @{
		Name = $Name
		CanonicalName = 'oras'
		Platform = if ($Linux) { 'linux/amd64' } else { 'windows/amd64' }
		Upstream = 'https://github.com/oras-project/oras'
		BuildRevision = 1
		GoToolchain = 'go1.26.6'
		IsLinux = [bool]$Linux
	}
	if ($Linux) { $global:TlcPackageConfig.RunsOn = 'ubuntu-22.04' }

	function global:Install-TlcPackage {
		$latest = Get-GitHubTag -Owner 'oras-project' -Repo 'oras' -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
		$upstreamVersion = $latest.Version.ToString()
		$packageVersion = [TlcSemanticVersion]::new("$upstreamVersion+$($TlcPackageConfig.BuildRevision)")
		$TlcPackageConfig.Version = $packageVersion.ToString()
		$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
		if ($TlcPackageConfig.UpToDate) { return }

		$outputName = if ($TlcPackageConfig.IsLinux) { 'oras' } else { 'oras.exe' }
		$executable = Get-TlcPkgPath $outputName
		Invoke-TlcVerifiedGoCommandBuild `
			-Module 'oras.land/oras' `
			-Version ([string]$latest.Name) `
			-Command 'oras.land/oras/cmd/oras' `
			-OutputPath $executable `
			-GoToolchain $TlcPackageConfig.GoToolchain `
			-LdFlags '-s -w -X oras.land/oras/internal/version.GitTreeState=clean'

		if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "patched ORAS source build did not produce $outputName" }
		if ($TlcPackageConfig.IsLinux) {
			& chmod '+x' $executable
			if ($LASTEXITCODE -ne 0) { throw 'failed to mark ORAS executable' }
		}
		Write-TlcVars @{ env = @{ path = Get-TlcPkgRoot } }
	}

	function global:Test-TlcPackageInstall {
		Toolchain exec (Get-TlcPkgUri) {
			oras version
		}
	}
}

function Initialize-TlcVerifiedGoCliPackage {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[Parameter(Mandatory=$true)][string]$CanonicalName,
		[Parameter(Mandatory=$true)][string]$Owner,
		[Parameter(Mandatory=$true)][string]$Repo,
		[Parameter(Mandatory=$true)][string]$Module,
		[Parameter(Mandatory=$true)][string]$Command,
		[Parameter(Mandatory=$true)][string]$BinaryName,
		[string[]]$VersionArguments = @('--version'),
		[hashtable]$MinimumModules = @{},
		[string]$BuildTags,
		[string]$LdFlagsTemplate,
		[switch]$UseModuleSource,
		[switch]$UseGitSource,
		[string]$EmbeddedAssetPattern,
		[string]$EmbeddedChecksumAssetPattern,
		[string]$EmbeddedRelativeDestination,
		[switch]$Linux
	)
	if ([bool]$EmbeddedAssetPattern -xor [bool]$EmbeddedRelativeDestination) {
		throw 'embedded asset pattern and destination must be supplied together'
	}
	if ($UseModuleSource -and $UseGitSource) { throw 'module-source and Git-source families are mutually exclusive' }
	if ($EmbeddedAssetPattern -and -not ($UseModuleSource -or $UseGitSource)) {
		throw 'embedded release assets require a source-tree build'
	}

	$global:TlcPackageConfig = @{
		Name = $Name
		CanonicalName = $CanonicalName
		Platform = if ($Linux) { 'linux/amd64' } else { 'windows/amd64' }
		Upstream = "https://github.com/$Owner/$Repo"
		BuildRevision = 1
		GoToolchain = 'go1.26.6'
		GitHubOwner = $Owner
		GitHubRepo = $Repo
		GoModule = $Module
		GoCommand = $Command
		BinaryName = $BinaryName
		VersionArguments = @($VersionArguments)
		MinimumModules = $MinimumModules
		BuildTags = $BuildTags
		LdFlagsTemplate = $LdFlagsTemplate
		UseModuleSource = [bool]$UseModuleSource
		UseGitSource = [bool]$UseGitSource
		EmbeddedAssetPattern = $EmbeddedAssetPattern
		EmbeddedChecksumAssetPattern = $EmbeddedChecksumAssetPattern
		EmbeddedRelativeDestination = $EmbeddedRelativeDestination
		IsLinux = [bool]$Linux
	}
	if ($Linux) { $global:TlcPackageConfig.RunsOn = 'ubuntu-22.04' }

	function global:Install-TlcPackage {
		$latest = Get-GitHubTag -Owner $TlcPackageConfig.GitHubOwner -Repo $TlcPackageConfig.GitHubRepo `
			-TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
		$upstreamVersion = $latest.Version.ToString()
		$packageVersion = [TlcSemanticVersion]::new("$upstreamVersion+$($TlcPackageConfig.BuildRevision)")
		$TlcPackageConfig.Version = $packageVersion.ToString()
		$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
		if ($TlcPackageConfig.UpToDate) { return }

		$commitSha = [string]$latest.CommitSha
		if ([string]$TlcPackageConfig.LdFlagsTemplate -match '\{commit\}' -and $commitSha -notmatch '^[0-9a-fA-F]{40}$') {
			throw "could not verify the source commit for $($TlcPackageConfig.GitHubOwner)/$($TlcPackageConfig.GitHubRepo) $($latest.Name)"
		}
		$ldFlags = [string]$TlcPackageConfig.LdFlagsTemplate
		if ($ldFlags) {
			$ldFlags = $ldFlags.Replace('{version}', $upstreamVersion).Replace('{tag}', [string]$latest.Name).Replace('{commit}', $commitSha)
		}

		$embeddedFilesPath = $null
		if ($TlcPackageConfig.EmbeddedAssetPattern) {
			$asset = Get-GitHubRelease -Owner $TlcPackageConfig.GitHubOwner -Repo $TlcPackageConfig.GitHubRepo `
				-AssetPattern $TlcPackageConfig.EmbeddedAssetPattern -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
			if ($asset.Version.ToString() -ne $upstreamVersion) {
				throw "embedded release asset version $($asset.Version) does not match source version $upstreamVersion"
			}
			$expectedSha256 = Get-TlcGitHubReleaseAssetSha256 -Uri $asset.URL
			if (-not $expectedSha256 -and $TlcPackageConfig.EmbeddedChecksumAssetPattern) {
				$checksum = Get-GitHubRelease -Owner $TlcPackageConfig.GitHubOwner -Repo $TlcPackageConfig.GitHubRepo `
					-AssetPattern $TlcPackageConfig.EmbeddedChecksumAssetPattern -TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
				$expectedSha256 = Get-TlcRemoteSha256 -ChecksumUri $checksum.URL -AssetName $asset.Name -Headers (Get-TlcGitHubHeaders)
			}
			if (-not $expectedSha256) { throw "no verified SHA-256 was published for $($asset.Name)" }

			$assetStage = Get-TlcStagingPath "$($TlcPackageConfig.CanonicalName)-source-assets"
			New-Item -ItemType Directory -Path $assetStage -Force | Out-Null
			$archivePath = Join-Path $assetStage $asset.Name
			Invoke-TlcWebRequest -Uri $asset.URL -OutFile $archivePath -ExpectedSha256 $expectedSha256 | Out-Null
			$embeddedFilesPath = Join-Path $assetStage 'embedded'
			Expand-TlcVerifiedTarGzArchive -Path $archivePath -Destination $embeddedFilesPath
			$embeddedFiles = @(Get-ChildItem -LiteralPath $embeddedFilesPath -File -Force)
			$embeddedDirectories = @(Get-ChildItem -LiteralPath $embeddedFilesPath -Directory -Force)
			if ($embeddedFiles.Count -eq 0 -or $embeddedDirectories.Count -gt 0 -or @($embeddedFiles | Where-Object Extension -ne '.yaml').Count -gt 0) {
				throw "embedded release asset $($asset.Name) does not contain only top-level YAML manifests"
			}
		}

		$outputName = if ($TlcPackageConfig.IsLinux) { [IO.Path]::GetFileNameWithoutExtension([string]$TlcPackageConfig.BinaryName) } else { [string]$TlcPackageConfig.BinaryName }
		$executable = Get-TlcPkgPath $outputName
		$build = @{
			Module = [string]$TlcPackageConfig.GoModule
			Version = [string]$latest.Name
			Command = [string]$TlcPackageConfig.GoCommand
			OutputPath = $executable
			MinimumModules = [hashtable]$TlcPackageConfig.MinimumModules
			GoToolchain = [string]$TlcPackageConfig.GoToolchain
		}
		if ($TlcPackageConfig.BuildTags) { $build.BuildTags = [string]$TlcPackageConfig.BuildTags }
		if ($ldFlags) { $build.LdFlags = $ldFlags }
		if ($TlcPackageConfig.UseModuleSource) { $build.UseModuleSource = $true }
		if ($TlcPackageConfig.UseGitSource) {
			$build.UseGitSource = $true
			$build.GitRepository = [string]$TlcPackageConfig.Upstream
			$build.GitRef = [string]$latest.Name
			$build.GitCommit = $commitSha
		}
		if ($embeddedFilesPath) {
			$build.EmbeddedFilesPath = $embeddedFilesPath
			$build.EmbeddedFilesRelativeDestination = [string]$TlcPackageConfig.EmbeddedRelativeDestination
		}
		Invoke-TlcVerifiedGoCommandBuild @build

		if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "patched $($TlcPackageConfig.CanonicalName) source build did not produce $outputName" }
		if ($TlcPackageConfig.IsLinux) {
			& chmod '+x' $executable
			if ($LASTEXITCODE -ne 0) { throw "failed to mark $($TlcPackageConfig.CanonicalName) executable" }
		}
		Write-TlcVars @{ env = @{ path = Get-TlcPkgRoot } }
	}

	function global:Test-TlcPackageInstall {
		$commandName = [IO.Path]::GetFileNameWithoutExtension([string]$TlcPackageConfig.BinaryName)
		$arguments = [string[]]@($TlcPackageConfig.VersionArguments)
		Toolchain exec (Get-TlcPkgUri) {
			$command = Get-Command $commandName -CommandType Application -ErrorAction Stop | Select-Object -First 1
			& $command.Source @arguments
			if ($LASTEXITCODE -ne 0) { throw "$commandName version check failed with exit code $LASTEXITCODE" }
		}
	}
}

function Initialize-TlcArgoCdPackage {
	param([Parameter(Mandatory=$true)][string]$Name, [switch]$Linux)
	Initialize-TlcVerifiedGoCliPackage -Name $Name -CanonicalName 'argocd' -Owner 'argoproj' -Repo 'argo-cd' `
		-Module 'github.com/argoproj/argo-cd/v3' -Command 'github.com/argoproj/argo-cd/v3/cmd' -BinaryName 'argocd.exe' `
		-VersionArguments @('version', '--client') -MinimumModules @{
			'github.com/go-git/go-git/v5' = 'v5.19.2'
			'golang.org/x/text' = 'v0.39.0'
			'google.golang.org/grpc' = 'v1.82.1'
			'oras.land/oras-go/v2' = 'v2.6.2'
		} -LdFlagsTemplate '-s -w -X github.com/argoproj/argo-cd/v3/common.version={version} -X github.com/argoproj/argo-cd/v3/common.gitCommit={commit} -X github.com/argoproj/argo-cd/v3/common.gitTag={tag} -X github.com/argoproj/argo-cd/v3/common.gitTreeState=clean' `
		-UseGitSource -Linux:$Linux
}

function Initialize-TlcFluxPackage {
	param([Parameter(Mandatory=$true)][string]$Name, [switch]$Linux)
	Initialize-TlcVerifiedGoCliPackage -Name $Name -CanonicalName 'flux' -Owner 'fluxcd' -Repo 'flux2' `
		-Module 'github.com/fluxcd/flux2/v2' -Command 'github.com/fluxcd/flux2/v2/cmd/flux' -BinaryName 'flux.exe' `
		-VersionArguments @('--version') -MinimumModules @{
			'github.com/go-git/go-git/v5' = 'v5.19.2'
			'golang.org/x/text' = 'v0.39.0'
			'google.golang.org/grpc' = 'v1.82.1'
		} -LdFlagsTemplate '-s -w -X main.VERSION={version}' -UseModuleSource `
		-EmbeddedAssetPattern '^manifests\.tar\.gz$' -EmbeddedChecksumAssetPattern '^flux_[0-9.]+_checksums\.txt$' `
		-EmbeddedRelativeDestination 'cmd/flux/manifests' -Linux:$Linux
}

function Initialize-TlcKubesealPackage {
	param([Parameter(Mandatory=$true)][string]$Name, [switch]$Linux)
	Initialize-TlcVerifiedGoCliPackage -Name $Name -CanonicalName 'kubeseal' -Owner 'bitnami-labs' -Repo 'sealed-secrets' `
		-Module 'github.com/bitnami/sealed-secrets' -Command 'github.com/bitnami/sealed-secrets/cmd/kubeseal' -BinaryName 'kubeseal.exe' `
		-VersionArguments @('--version') -MinimumModules @{ 'golang.org/x/text' = 'v0.39.0' } `
		-LdFlagsTemplate '-s -w -X main.VERSION={version}' -Linux:$Linux
}

function Initialize-TlcSternPackage {
	param([Parameter(Mandatory=$true)][string]$Name, [switch]$Linux)
	Initialize-TlcVerifiedGoCliPackage -Name $Name -CanonicalName 'stern' -Owner 'stern' -Repo 'stern' `
		-Module 'github.com/stern/stern' -Command 'github.com/stern/stern' -BinaryName 'stern.exe' `
		-VersionArguments @('--version') -MinimumModules @{
			'golang.org/x/net' = 'v0.56.0'
			'golang.org/x/text' = 'v0.39.0'
		} -LdFlagsTemplate '-s -w -X github.com/stern/stern/cmd.version={version} -X github.com/stern/stern/cmd.commit={commit}' -Linux:$Linux
}

function Initialize-TlcSyftPackage {
	param([Parameter(Mandatory=$true)][string]$Name, [switch]$Linux)
	Initialize-TlcVerifiedGoCliPackage -Name $Name -CanonicalName 'syft' -Owner 'anchore' -Repo 'syft' `
		-Module 'github.com/anchore/syft' -Command 'github.com/anchore/syft/cmd/syft' -BinaryName 'syft.exe' `
		-VersionArguments @('version') -LdFlagsTemplate '-s -w -X main.version={version} -X main.gitCommit={commit}' -Linux:$Linux
}

function Initialize-TlcTalosctlPackage {
	param([Parameter(Mandatory=$true)][string]$Name, [switch]$Linux)
	Initialize-TlcVerifiedGoCliPackage -Name $Name -CanonicalName 'talosctl' -Owner 'siderolabs' -Repo 'talos' `
		-Module 'github.com/siderolabs/talos' -Command 'github.com/siderolabs/talos/cmd/talosctl' -BinaryName 'talosctl.exe' `
		-VersionArguments @('version', '--client') -BuildTags 'grpcnotrace' -UseGitSource -Linux:$Linux
}

function Initialize-TlcKubectlPackage {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[switch]$Linux
	)

	$global:TlcPackageConfig = @{
		Name = $Name
		CanonicalName = 'kubectl'
		Platform = if ($Linux) { 'linux/amd64' } else { 'windows/amd64' }
		BuildRevision = 1
		GoToolchain = 'go1.26.6'
		KubernetesNetVersion = 'v0.56.0'
		KubernetesSysVersion = 'v0.46.0'
		KubernetesTextVersion = 'v0.39.0'
		IsLinux = [bool]$Linux
		SourceEntrypoint = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'assets\kubectl\main.go'))
	}
	if ($Linux) { $global:TlcPackageConfig.RunsOn = 'ubuntu-22.04' }

	function global:Install-TlcPackage {
		$response = Invoke-TlcWebRequest -Uri 'https://dl.k8s.io/release/stable.txt'
		$content = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString([byte[]]$response.Content) } else { [string]$response.Content }
		$tag = $content.Trim()
		if ($tag -notmatch '^v(1)\.([0-9]+)\.([0-9]+)$') { throw "unexpected kubectl stable version: $tag" }
		$upstreamVersion = [TlcSemanticVersion]::new($tag, '^v([0-9]+)\.([0-9]+)\.([0-9]+)$')
		$packageVersion = [TlcSemanticVersion]::new("$($upstreamVersion.ToString())+$($TlcPackageConfig.BuildRevision)")
		$TlcPackageConfig.Version = $packageVersion.ToString()
		$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
		if ($TlcPackageConfig.UpToDate) { return }

		$moduleVersion = "v0.$($upstreamVersion.Minor).$($upstreamVersion.Patch)"
		$pkgRoot = Get-TlcPkgRoot
		New-Item -Path $pkgRoot -ItemType Directory -Force -ErrorAction Ignore | Out-Null
		$sourceRoot = Join-Path ([IO.Path]::GetTempPath()) "tlc-kubectl-$([Guid]::NewGuid().ToString('n'))"
		$locationPushed = $false
		$previous = @{
			CGO_ENABLED = $env:CGO_ENABLED
			GOFLAGS = $env:GOFLAGS
			GONOSUMDB = $env:GONOSUMDB
			GOPRIVATE = $env:GOPRIVATE
			GOPROXY = $env:GOPROXY
			GOSUMDB = $env:GOSUMDB
			GOTOOLCHAIN = $env:GOTOOLCHAIN
			GOWORK = $env:GOWORK
		}
		try {
			$env:CGO_ENABLED = '0'
			$env:GOFLAGS = '-mod=mod'
			$env:GONOSUMDB = $null
			$env:GOPRIVATE = $null
			$env:GOPROXY = 'https://proxy.golang.org,direct'
			$env:GOSUMDB = 'sum.golang.org'
			$env:GOTOOLCHAIN = $TlcPackageConfig.GoToolchain
			$env:GOWORK = 'off'

			New-Item -Path $sourceRoot -ItemType Directory -Force | Out-Null
			Copy-Item -LiteralPath $TlcPackageConfig.SourceEntrypoint -Destination (Join-Path $sourceRoot 'main.go') -Force
			Push-Location $sourceRoot
			$locationPushed = $true
			$go = Get-TlcApplicationPath -Name 'go'

			Invoke-TlcNativeCommand -FilePath $go `
				-ArgumentList @('mod', 'init', 'github.com/allsagetech/toolchains-kubectl-build') `
				-FailureMessage 'kubectl build module initialization failed'
			$modules = @(
				"k8s.io/component-base@$moduleVersion"
				"k8s.io/kubectl@$moduleVersion"
				"k8s.io/client-go@$moduleVersion"
				"golang.org/x/net@$($TlcPackageConfig.KubernetesNetVersion)"
				"golang.org/x/sys@$($TlcPackageConfig.KubernetesSysVersion)"
				"golang.org/x/text@$($TlcPackageConfig.KubernetesTextVersion)"
			)
			Invoke-TlcNativeCommand -FilePath $go -ArgumentList (@('get') + $modules) `
				-FailureMessage 'checksum-verified kubectl dependency resolution failed'
			Invoke-TlcNativeCommand -FilePath $go -ArgumentList @('mod', 'tidy') `
				-FailureMessage 'kubectl dependency cleanup failed'

			$resolvedModules = @{}
			$resolvedModuleText = Invoke-TlcNativeCommand -FilePath $go -ArgumentList @('list', '-m', 'all') `
				-FailureMessage 'kubectl dependency verification failed' -PassThru
			foreach ($line in @($resolvedModuleText -split '\r?\n')) {
				$fields = @(([string]$line).Trim() -split '\s+')
				if ($fields.Count -ge 2) { $resolvedModules[$fields[0]] = $fields[1] }
			}
			$requiredModules = [ordered]@{
				'k8s.io/component-base' = $moduleVersion
				'k8s.io/kubectl' = $moduleVersion
				'k8s.io/client-go' = $moduleVersion
				'golang.org/x/net' = $TlcPackageConfig.KubernetesNetVersion
				'golang.org/x/sys' = $TlcPackageConfig.KubernetesSysVersion
				'golang.org/x/text' = $TlcPackageConfig.KubernetesTextVersion
			}
			foreach ($required in $requiredModules.GetEnumerator()) {
				if ([string]$resolvedModules[$required.Key] -ne [string]$required.Value) {
					throw "kubectl dependency $($required.Key) resolved to '$($resolvedModules[$required.Key])' instead of '$($required.Value)'"
				}
			}

			$downloadJson = Invoke-TlcNativeCommand -FilePath $go `
				-ArgumentList @('mod', 'download', '-json', "k8s.io/kubectl@$moduleVersion") `
				-FailureMessage 'kubectl module provenance lookup failed' -PassThru
			$download = $downloadJson | ConvertFrom-Json
			$gitCommit = [string]$download.Origin.Hash
			if ($gitCommit -notmatch '^[0-9a-f]{40}$') { throw 'kubectl module provenance did not contain a Git commit' }
			$moduleInfo = Get-Content -LiteralPath $download.Info -Raw | ConvertFrom-Json
			$buildDate = ([datetime]$moduleInfo.Time).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
			$ldflags = @(
				'-s'
				'-w'
				"-X=k8s.io/component-base/version.gitMajor=$($upstreamVersion.Major)"
				"-X=k8s.io/component-base/version.gitMinor=$($upstreamVersion.Minor)"
				"-X=k8s.io/component-base/version.gitVersion=$tag"
				"-X=k8s.io/component-base/version.gitCommit=$gitCommit"
				'-X=k8s.io/component-base/version.gitTreeState=clean'
				"-X=k8s.io/component-base/version.buildDate=$buildDate"
			) -join ' '

			$outputName = if ($TlcPackageConfig.IsLinux) { 'kubectl' } else { 'kubectl.exe' }
			Invoke-TlcNativeCommand -FilePath $go `
				-ArgumentList @('build', '-trimpath', '-buildvcs=false', '-ldflags', $ldflags, '-o', (Get-TlcPkgPath $outputName), '.') `
				-FailureMessage 'verified kubectl source build failed'
		} finally {
			if ($locationPushed) { Pop-Location }
			foreach ($name in $previous.Keys) {
				if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue }
				else { Set-Item -LiteralPath "env:$name" -Value $previous[$name] }
			}
			if (Test-Path -LiteralPath $sourceRoot) { Remove-Item -LiteralPath $sourceRoot -Recurse -Force }
		}

		$outputName = if ($TlcPackageConfig.IsLinux) { 'kubectl' } else { 'kubectl.exe' }
		$executable = Get-TlcPkgPath $outputName
		if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "kubectl source build did not produce $outputName" }
		if ($TlcPackageConfig.IsLinux -and -not (Test-TlcHostIsWindows)) {
			& chmod '+x' $executable
			if ($LASTEXITCODE -ne 0) { throw 'failed to mark kubectl executable' }
		}
		Write-TlcVars @{ env = @{ path = $pkgRoot } }
	}

	function global:Test-TlcPackageInstall {
		Toolchain exec (Get-TlcPkgUri) { kubectl version --client }
	}
}

function Initialize-TlcGitHubCliPackage {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[Parameter(Mandatory=$true)][string]$CanonicalName,
		[Parameter(Mandatory=$true)][string]$Owner,
		[Parameter(Mandatory=$true)][string]$Repo,
		[Parameter(Mandatory=$true)][string]$AssetPattern,
		[Parameter(Mandatory=$true)][string]$BinaryName,
		[Parameter(Mandatory=$true)][ValidateSet('zip', 'tar.gz', 'direct')][string]$ArchiveType,
		[string]$ChecksumAssetPattern,
		[string[]]$VersionArguments = @('--version'),
		[switch]$Linux
	)

	$global:TlcPackageConfig = @{
		Name = $Name
		CanonicalName = $CanonicalName
		Platform = if ($Linux) { 'linux/amd64' } else { 'windows/amd64' }
		Upstream = "https://github.com/$Owner/$Repo"
		GitHubOwner = $Owner
		GitHubRepo = $Repo
		AssetPattern = $AssetPattern
		BinaryName = $BinaryName
		ArchiveType = $ArchiveType
		ChecksumAssetPattern = $ChecksumAssetPattern
		VersionArguments = @($VersionArguments)
		IsLinux = [bool]$Linux
	}
	if ($Linux) { $global:TlcPackageConfig.RunsOn = 'ubuntu-22.04' }

	function global:Install-TlcPackage {
		$asset = Get-GitHubRelease -Owner $TlcPackageConfig.GitHubOwner -Repo $TlcPackageConfig.GitHubRepo `
			-AssetPattern $TlcPackageConfig.AssetPattern -TagPattern '^v?([0-9]+)\.([0-9]+)\.([0-9]+)$'
		$TlcPackageConfig.Version = $asset.Version.ToString()
		$TlcPackageConfig.UpToDate = -not $asset.Version.LaterThan($TlcPackageConfig.Latest)
		if ($TlcPackageConfig.UpToDate) { return }

		$expectedSha256 = Get-TlcGitHubReleaseAssetSha256 -Uri $asset.URL
		if (-not $expectedSha256 -and $TlcPackageConfig.ChecksumAssetPattern) {
			$checksum = Get-GitHubRelease -Owner $TlcPackageConfig.GitHubOwner -Repo $TlcPackageConfig.GitHubRepo `
				-AssetPattern $TlcPackageConfig.ChecksumAssetPattern -TagPattern '^v?([0-9]+)\.([0-9]+)\.([0-9]+)$'
			$expectedSha256 = Get-TlcRemoteSha256 -ChecksumUri $checksum.URL -AssetName $asset.Name -Headers (Get-TlcGitHubHeaders)
		}
		if (-not $expectedSha256) { throw "no verified SHA-256 was published for $($asset.Name)" }

		$stage = Get-TlcStagingPath $TlcPackageConfig.CanonicalName
		New-Item -Path $stage -ItemType Directory -Force | Out-Null
		$download = Join-Path $stage $asset.Name
		Invoke-TlcWebRequest -Uri $asset.URL -OutFile $download -ExpectedSha256 $expectedSha256 | Out-Null
		$extract = Join-Path $stage 'extract'
		New-Item -Path $extract -ItemType Directory -Force | Out-Null
		switch ([string]$TlcPackageConfig.ArchiveType) {
			'zip' { Expand-Archive -LiteralPath $download -DestinationPath $extract -Force }
			'tar.gz' {
				$tar = Get-TlcApplicationPath -Name 'tar'
				& $tar '-xzf' $download '-C' $extract
				if ($LASTEXITCODE -ne 0) { throw "failed to extract $($asset.Name) with exit code $LASTEXITCODE" }
			}
			'direct' { Copy-Item -LiteralPath $download -Destination (Join-Path $extract $TlcPackageConfig.BinaryName) -Force }
		}
		$source = Get-ChildItem -LiteralPath $extract -Recurse -File | Where-Object { $_.Name -ceq $TlcPackageConfig.BinaryName } | Select-Object -First 1
		if (-not $source) { throw "$($asset.Name) did not contain $($TlcPackageConfig.BinaryName)" }
		$pkgRoot = Get-TlcPkgRoot
		New-Item -Path $pkgRoot -ItemType Directory -Force | Out-Null
		$output = Join-Path $pkgRoot $TlcPackageConfig.BinaryName
		Copy-Item -LiteralPath $source.FullName -Destination $output -Force
		if ($TlcPackageConfig.IsLinux) {
			& chmod '+x' $output
			if ($LASTEXITCODE -ne 0) { throw "failed to mark $($TlcPackageConfig.BinaryName) executable" }
		}
		Write-TlcVars @{ env = @{ path = $pkgRoot } }
	}

	function global:Test-TlcPackageInstall {
		$commandName = [IO.Path]::GetFileNameWithoutExtension([string]$TlcPackageConfig.BinaryName)
		$arguments = [string[]]@($TlcPackageConfig.VersionArguments)
		Toolchain exec (Get-TlcPkgUri) {
			$command = Get-Command $commandName -CommandType Application -ErrorAction Stop | Select-Object -First 1
			& $command.Source @arguments
			if ($LASTEXITCODE -ne 0) { throw "$commandName version check failed with exit code $LASTEXITCODE" }
		}
	}
}
