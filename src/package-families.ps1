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
