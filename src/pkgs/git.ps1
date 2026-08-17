<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'git'
	BuildRevision = 1
	GitLfsVersion = 'v3.7.1'
	GoToolchain = 'go1.26.6'
	PatchedNetVersion = 'v0.56.0'
	PatchedTextVersion = 'v0.39.0'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'git-for-windows'
		Repo = 'git'
		AssetPattern = 'PortableGit-.+?64-bit\.7z\.exe'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)\.windows(\.[0-9]+)$'
	}
	$Asset = Get-GitHubRelease @Params
	$packageVersion = Add-TlcPackagingRevision -Version $Asset.Version.ToString() -Revision ([int]$TlcPackageConfig.BuildRevision)
	$packageSemanticVersion = [TlcSemanticVersion]::new($packageVersion)
	$TlcPackageConfig.UpToDate = -not $packageSemanticVersion.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $packageVersion
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$git = "$env:Temp\$($Asset.Name)"
	Invoke-TlcWebRequest -Uri $Asset.URL -OutFile $git
	$sevenZipExe = Get-Tlc7ZipExecutable
	& $sevenZipExe x ("-o{0}" -f (Get-TlcPkgRoot)) $git | Out-Null
	$gitLfsTargets = @(Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -File -Filter 'git-lfs.exe')
	if ($gitLfsTargets.Count -eq 0) { throw 'PortableGit did not contain git-lfs.exe.' }
	$patchedGitLfs = Get-TlcStagingPath 'git-lfs-patched.exe'
	Invoke-TlcVerifiedGoCommandBuild `
		-Module 'github.com/git-lfs/git-lfs/v3' `
		-Version $TlcPackageConfig.GitLfsVersion `
		-Command 'github.com/git-lfs/git-lfs/v3' `
		-OutputPath $patchedGitLfs `
		-MinimumModules @{
			'golang.org/x/net' = $TlcPackageConfig.PatchedNetVersion
			'golang.org/x/text' = $TlcPackageConfig.PatchedTextVersion
		} `
		-GoToolchain $TlcPackageConfig.GoToolchain `
		-UseModuleSource
	foreach ($target in $gitLfsTargets) {
		Copy-Item -LiteralPath $patchedGitLfs -Destination $target.FullName -Force
	}
	Remove-Item -LiteralPath $patchedGitLfs -Force -ErrorAction SilentlyContinue
	& (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'git.exe' | Select-Object -First 1) config --system --unset credential.helper
	Write-TlcVars @{
		env = @{
			path = (@(
				(Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'gitk.exe' | Select-Object -First 1).DirectoryName,
				(Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'sed.exe' | Select-Object -First 1).DirectoryName,
				(Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'curl.exe' | Select-Object -First 1).DirectoryName
			) -join ';')
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		git --version
		git lfs version
		curl.exe --version
		sed --version
	}
}
