<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'kind-linux'
	RunsOn = 'ubuntu-22.04'
}

function global:Install-TlcPackage {
	$asset = Get-GitHubRelease `
		-Owner 'kubernetes-sigs' `
		-Repo 'kind' `
		-AssetPattern '^kind-linux-amd64$' `
		-TagPattern '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'

	$TlcPackageConfig.Version = $asset.Version.ToString()
	$TlcPackageConfig.UpToDate = -not $asset.Version.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }

	New-Item -Path (Get-TlcPkgRoot) -ItemType Directory -Force -ErrorAction Ignore | Out-Null
	$expectedSha256 = if ($asset.ExpectedSha256) {
		$asset.ExpectedSha256
	} else {
		Get-TlcRemoteSha256 -ChecksumUri "$($asset.URL).sha256sum" -AssetName $asset.Name -Headers (Get-TlcGitHubHeaders)
	}
	$executable = Get-TlcPkgPath 'kind'
	Invoke-TlcWebRequest -Uri $asset.URL -OutFile $executable -ExpectedSha256 $expectedSha256
	& chmod '+x' $executable
	if ($LASTEXITCODE -ne 0) { throw 'failed to mark kind executable' }
	Write-TlcVars @{ env = @{ path = (Get-TlcPkgRoot) } }
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		kind version
	}
}
