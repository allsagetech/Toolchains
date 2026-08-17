<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'vscode'
	BuildRevision = 1
	Vex = '.github/vex/vscode.openvex.json'
	SecurityOverlays = @(
		@{ Name = '@github/copilot'; Version = '1.0.43'; ExpectedSha512 = 'd853bcdb902ae1bc261dc5d5ca9956f82a59689154623aadaa30469ee78cdf582ee2e7e7e917aeaf3076b30050e9b9f83eabb2cb629ea1d3113e94fa25a2cc87'; Paths = @('extensions\copilot\node_modules\@github\copilot', 'node_modules\@github\copilot') }
		@{ Name = 'undici'; Version = '7.29.0'; ExpectedSha512 = '203c5f95e2e699b4ac91f5925004e23759df9f6ac3baf9cc3aa6f909647dda221fa2303451dfae94e000110e7b2cfafdad69acade5327f9970c9aa3eec634d57'; Paths = @('node_modules\undici') }
		@{ Name = 'tar'; Version = '7.5.19'; ExpectedSha512 = 'e0b7845a5f7ab709d2d90ec1cf8306aa06b32ea3be84937adc66715e822a8754f75707980fdf7b81b53522d36c41a7eaa974d7779585c8575178bb70bd104d8b'; Paths = @('node_modules\tar') }
		@{ Name = 'shell-quote'; Version = '1.9.0'; ExpectedSha512 = '228bfe27016fff61dc4e973034c29df3e21635bf2d6e84093504e4018fcb2d52bb8061fd8f2f8b1a456a3f17de90797ec8c9a2a97b337465978247e697b863a8'; Paths = @('node_modules\shell-quote') }
		@{ Name = 'ip-address'; Version = '10.5.0'; ExpectedSha512 = '4794a754b26681862f7f6176660c120677a5cf91b8ab9031202dbbec60df51a35bad928d00d7010bb447a9861e3e5b337f8901a2556425ab86d198c71c5879e6'; Paths = @('node_modules\ip-address') }
		@{ Name = 'form-data'; Version = '4.0.6'; ExpectedSha512 = 'bca6ad021e129557e06eff98b66862463844309b18a6c1b5636acc42d47e49549bcadb120f5606cc321cac026674579cf3cbbff95a069b19e5fbcd202f5b5109'; Paths = @('node_modules\form-data') }
		@{ Name = 'ws'; Version = '8.21.0'; ExpectedSha512 = '56ca76f1bec345c8a6150bebaaed967a4df3d626310c25aa1d807c42c9e4fd2e117da090ccf18fc8136e563255ddc77a5222ad52da7ab0d33bee05afcdc087fa'; Paths = @('node_modules\ws') }
		@{ Name = 'ws'; Version = '7.5.11'; ExpectedSha512 = 'cd2e7839e9fd6c84eda7b929d9733703276b088ab50fe1f024eb87f9cf9ee0b7e92ff968b4fe68b228ddf94a0c9f1c006a6d4637c4782ad2c0c88ac870136988'; Paths = @('node_modules\chrome-remote-interface\node_modules\ws') }
		@{ Name = 'axios'; Version = '1.18.1'; ExpectedSha512 = 'de74ef165be99fd66efd190752ab5cefff9a978529456e5acfbd5aa79cdc729e9ef1101813384c4de717f03cf5c160d8acfa54a01d4701010610012f52bed2f6'; Paths = @('node_modules\axios') }
	)
}

function global:Install-TlcPackage {
	$metadata = Invoke-TlcRestMethod -Uri 'https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest'
	$AssetURL = [string]$metadata.url
	$expectedSha256 = [string]$metadata.sha256hash
	if (-not $AssetURL -or $expectedSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'VS Code update metadata is missing the archive URL or SHA-256.' }
	$Version = Add-TlcPackagingRevision -Version ([string]$metadata.productVersion) -Revision ([int]$TlcPackageConfig.BuildRevision)
	$PackageVersion = [TlcSemanticVersion]::new($Version)
	$TlcPackageConfig.UpToDate = -not $PackageVersion.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $PackageVersion.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Params = @{
		AssetName = 'vscode.zip'
		AssetURL = $AssetURL
		ExpectedSha256 = $expectedSha256
	}
	Install-BuildTool @Params
	$appRoots = @(Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Directory -Filter 'app' | Where-Object {
		$_.Parent -and $_.Parent.Name -eq 'resources'
	})
	if ($appRoots.Count -ne 1) { throw "Expected exactly one VS Code resources/app directory, found $($appRoots.Count)." }
	$appRoot = $appRoots[0].FullName
	foreach ($overlay in @($TlcPackageConfig.SecurityOverlays)) {
		foreach ($relativePath in @($overlay.Paths)) {
			$destination = Join-Path $appRoot $relativePath
			$manifestPath = Join-Path $destination 'package.json'
			if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
				Write-Host "Skipping removed VS Code dependency path: $relativePath"
				continue
			}
			$installedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
			if ([string]$installedManifest.name -cne [string]$overlay.Name) {
				throw "VS Code dependency identity mismatch at $relativePath`: expected $($overlay.Name), got $($installedManifest.name)."
			}
			$installedVersion = [TlcSemanticVersion]::new([string]$installedManifest.version)
			$minimumVersion = [TlcSemanticVersion]::new([string]$overlay.Version)
			if (-not $minimumVersion.LaterThan($installedVersion)) {
				Write-Host "Keeping VS Code dependency $($overlay.Name)@$installedVersion; fixed floor is $minimumVersion."
				continue
			}
			Install-TlcPinnedNpmArchive -Name $overlay.Name -Version $overlay.Version `
				-ExpectedSha512 $overlay.ExpectedSha512 -Destination $destination
		}
	}
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'code.cmd' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		code --version
	}
}
