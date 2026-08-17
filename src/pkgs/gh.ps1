<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'gh'
	GoToolchain = 'go1.26.6'
	BuildRevision = 1
	PatchedCryptoVersion = 'v0.54.0'
	PatchedNetVersion = 'v0.56.0'
	PatchedTextVersion = 'v0.40.0'
	PatchedGrpcVersion = 'v1.82.1'
	PatchedRekorVersion = 'v1.5.3'
}

function global:Install-TlcPackage {
    $Params = @{
        Owner        = 'cli'
        Repo         = 'cli'
        TagPattern   = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
    }

	$Latest = Get-GitHubTag @Params
	$upstreamVersion = $Latest.Version.ToString()
	$packageVersion = [TlcSemanticVersion]::new("$upstreamVersion+$($TlcPackageConfig.BuildRevision)")
	$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $packageVersion.ToString()

    if ($TlcPackageConfig.UpToDate) {
        return
    }

	$ldflags = "-s -w -X github.com/cli/cli/v2/internal/build.Version=$upstreamVersion"
	Invoke-TlcVerifiedGoCommandBuild `
		-Module 'github.com/cli/cli/v2' `
		-Version ([string]$Latest.Name) `
		-Command 'github.com/cli/cli/v2/cmd/gh' `
		-OutputPath (Get-TlcPkgPath 'gh.exe') `
		-MinimumModules @{
			'github.com/sigstore/rekor' = $TlcPackageConfig.PatchedRekorVersion
			'golang.org/x/crypto' = $TlcPackageConfig.PatchedCryptoVersion
			'golang.org/x/net' = $TlcPackageConfig.PatchedNetVersion
			'golang.org/x/text' = $TlcPackageConfig.PatchedTextVersion
			'google.golang.org/grpc' = $TlcPackageConfig.PatchedGrpcVersion
		} `
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
        gh --version
    }
}
