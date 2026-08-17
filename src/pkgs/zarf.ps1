<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'zarf'
	GoToolchain = 'go1.26.6'
	BuildRevision = 1
	PatchedContainerdVersion = 'v1.7.33'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'zarf-dev'
		Repo = 'zarf'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
	}
	$Latest = Get-GitHubTag @Params
	$upstreamVersion = $Latest.Version.ToString()
	$packageVersion = [TlcSemanticVersion]::new("$upstreamVersion+$($TlcPackageConfig.BuildRevision)")
	$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $packageVersion.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}

	$ldflags = "-s -w -X github.com/zarf-dev/zarf/src/config.CLIVersion=$($Latest.Name)"
	Invoke-TlcVerifiedGoCommandBuild `
		-Module 'github.com/zarf-dev/zarf' `
		-Version ([string]$Latest.Name) `
		-Command 'github.com/zarf-dev/zarf' `
		-OutputPath (Get-TlcPkgPath 'zarf.exe') `
		-MinimumModules @{ 'github.com/containerd/containerd' = $TlcPackageConfig.PatchedContainerdVersion } `
		-GoToolchain $TlcPackageConfig.GoToolchain `
		-LdFlags $ldflags

	Write-TlcVars @{
		env = @{
			path = Get-TlcPkgRoot
		}
	}
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        zarf version
    }
}
