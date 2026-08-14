<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function Initialize-TlcNodePackage {
	param(
		[Parameter(Mandatory=$true)][int]$Major,
		[string]$LifecycleNote
	)

	$global:TlcPackageConfig = @{
		Name = 'node'
		Matcher = "^node-$Major\."
		FamilyMajor = $Major
		LifecycleNote = $LifecycleNote
	}

	function global:Install-TlcPackage {
		$major = [int]$TlcPackageConfig.FamilyMajor
		$latest = Get-GitHubTag -Owner 'nodejs' -Repo 'node' -TagPattern "^v($major)\.([0-9]+)\.([0-9]+)$"
		$TlcPackageConfig.UpToDate = -not $latest.Version.LaterThan($TlcPackageConfig.Latest)
		$TlcPackageConfig.Version = $latest.Version.ToString()
		if ($TlcPackageConfig.UpToDate) { return }

		$tag = $latest.name
		$assetName = "node-$tag-win-x64.zip"
		Install-BuildTool -AssetName $assetName -AssetURL "https://nodejs.org/dist/$tag/$assetName"
		Write-TlcVars @{
			env = @{
				path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'node.exe' | Select-Object -First 1).DirectoryName
			}
		}
	}

	function global:Test-TlcPackageInstall {
		Toolchain exec (Get-TlcPkgUri) { node --version }
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

function Initialize-TlcKubectlPackage {
	param(
		[Parameter(Mandatory=$true)][string]$Name,
		[switch]$Linux
	)

	$global:TlcPackageConfig = @{
		Name = $Name
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
