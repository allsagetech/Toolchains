<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'helm'
	GoToolchain = 'go1.26.6'
	BuildRevision = 1
	PatchedOrasVersion = 'v2.6.2'
}

function global:Install-TlcPackage {
    $Params = @{
        Owner      = 'helm'
        Repo       = 'helm'
        TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
    }
    $Latest = Get-GitHubTag @Params

	$upstreamVersion = $Latest.Version.ToString()
	$packageVersion = [TlcSemanticVersion]::new("$upstreamVersion+$($TlcPackageConfig.BuildRevision)")
	$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version  = $packageVersion.ToString()

    if ($TlcPackageConfig.UpToDate) {
        return
    }
	$tag = [string]$Latest.Name
	$outputPath = Get-TlcPkgPath 'helm.exe'
	$ldflags = "-s -w -X helm.sh/helm/v4/internal/version.version=$tag -X helm.sh/helm/v4/internal/version.metadata= -X helm.sh/helm/v4/internal/version.gitTreeState=clean"
	Invoke-TlcVerifiedGoCommandBuild `
		-Module 'helm.sh/helm/v4' `
		-Version $tag `
		-Command 'helm.sh/helm/v4/cmd/helm' `
		-OutputPath $outputPath `
		-MinimumModules @{ 'oras.land/oras-go/v2' = $TlcPackageConfig.PatchedOrasVersion } `
		-GoToolchain $TlcPackageConfig.GoToolchain `
		-LdFlags $ldflags

    Write-TlcVars @{
        env = @{
			path = (Get-TlcPkgRoot)
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        helm version
    }
}
