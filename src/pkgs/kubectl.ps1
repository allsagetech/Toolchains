<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'kubectl'
}

function global:Install-TlcPackage {
	$response = Invoke-TlcWebRequest -Uri 'https://dl.k8s.io/release/stable.txt'
	$content = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString([byte[]]$response.Content) } else { [string]$response.Content }
	$tag = $content.Trim()
	if ($tag -notmatch '^v([0-9]+)\.([0-9]+)\.([0-9]+)$') { throw "unexpected kubectl stable version: $tag" }
	$version = [TlcSemanticVersion]::new($tag, '^v([0-9]+)\.([0-9]+)\.([0-9]+)$')
	$TlcPackageConfig.Version = $version.ToString()
	$TlcPackageConfig.UpToDate = -not $version.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }

	New-Item -Path (Get-TlcPkgRoot) -ItemType Directory -Force -ErrorAction Ignore | Out-Null
	$download = "https://dl.k8s.io/release/$tag/bin/windows/amd64/kubectl.exe"
	$expectedSha256 = Get-TlcRemoteSha256 -ChecksumUri "$download.sha256"
	Invoke-TlcWebRequest -Uri $download -OutFile (Get-TlcPkgPath 'kubectl.exe') -ExpectedSha256 $expectedSha256
	Write-TlcVars @{ env = @{ path = (Get-TlcPkgRoot) } }
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		kubectl version --client
	}
}
