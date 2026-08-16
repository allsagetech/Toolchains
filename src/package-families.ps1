<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function Install-TlcPinnedNpmArchive {
	param(
		[Parameter(Mandatory=$true)][ValidatePattern('^[a-z0-9][a-z0-9._-]*$')][string]$Name,
		[Parameter(Mandatory=$true)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')][string]$Version,
		[Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{128}$')][string]$ExpectedSha512,
		[Parameter(Mandatory=$true)][string]$Destination
	)

	$encodedName = [uri]::EscapeDataString($Name)
	$archiveBaseName = "$($Name.Replace('/', '-'))-$Version"
	$archiveName = "$archiveBaseName.tgz"
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

			& $go mod init 'github.com/allsagetech/toolchains-kubectl-build'
			if ($LASTEXITCODE -ne 0) { throw "kubectl build module initialization failed with exit code $LASTEXITCODE" }
			$modules = @(
				"k8s.io/component-base@$moduleVersion"
				"k8s.io/kubectl@$moduleVersion"
				"k8s.io/client-go@$moduleVersion"
				"golang.org/x/net@$($TlcPackageConfig.KubernetesNetVersion)"
				"golang.org/x/sys@$($TlcPackageConfig.KubernetesSysVersion)"
				"golang.org/x/text@$($TlcPackageConfig.KubernetesTextVersion)"
			)
			& $go get @modules
			if ($LASTEXITCODE -ne 0) { throw "checksum-verified kubectl dependency resolution failed with exit code $LASTEXITCODE" }
			& $go mod tidy
			if ($LASTEXITCODE -ne 0) { throw "kubectl dependency cleanup failed with exit code $LASTEXITCODE" }

			$resolvedModules = @{}
			foreach ($line in @(& $go list -m all)) {
				$fields = @(([string]$line).Trim() -split '\s+')
				if ($fields.Count -ge 2) { $resolvedModules[$fields[0]] = $fields[1] }
			}
			if ($LASTEXITCODE -ne 0) { throw "kubectl dependency verification failed with exit code $LASTEXITCODE" }
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

			$downloadJson = (& $go mod download -json "k8s.io/kubectl@$moduleVersion" | Out-String)
			if ($LASTEXITCODE -ne 0) { throw "kubectl module provenance lookup failed with exit code $LASTEXITCODE" }
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
			& $go build -trimpath -buildvcs=false -ldflags $ldflags -o (Get-TlcPkgPath $outputName) .
			if ($LASTEXITCODE -ne 0) { throw "verified kubectl source build failed with exit code $LASTEXITCODE" }
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
