<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
	[string]$Repository = 'allsagetech/toolchains',
	[Parameter(Mandatory=$true)][string]$CatalogPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-health-$([Guid]::NewGuid().ToString('n'))"
try {
	[void][IO.Directory]::CreateDirectory($tempRoot)
	$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
	if ([int]$catalog.schemaVersion -ne 1 -or [string]$catalog.repository -ne $Repository -or $null -eq $catalog.packages) { throw 'invalid package health catalog plan' }
	$bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $CatalogPath).Path)
	$compressedStream = [IO.MemoryStream]::new()
	try {
		$gzip = [IO.Compression.GZipStream]::new($compressedStream, [IO.Compression.CompressionMode]::Compress, $true)
		try { $gzip.Write($bytes, 0, $bytes.Length) } finally { $gzip.Dispose() }
		$encoded = [Convert]::ToBase64String($compressedStream.ToArray())
	} finally { $compressedStream.Dispose() }
	$dockerfile = Join-Path $tempRoot 'Dockerfile'
	[IO.File]::WriteAllText($dockerfile, "FROM scratch`nARG CATALOG`nLABEL io.allsagetech.toolchain.healthCatalogGzipBase64=`$CATALOG`nLABEL org.opencontainers.image.title=toolchains-package-health-catalog`n", [Text.UTF8Encoding]::new($false))
	$staging = "$Repository`:staging-health-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
	& docker build --build-arg "CATALOG=$encoded" -t $staging $tempRoot
	if ($LASTEXITCODE -ne 0) { throw 'health catalog image build failed' }
	& docker push $staging
	if ($LASTEXITCODE -ne 0) { throw 'health catalog staging push failed' }
	$inspect = (& docker buildx imagetools inspect $staging --format '{{json .Manifest}}' | Out-String).Trim() | ConvertFrom-Json
	$digest = [string]$inspect.digest
	if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw 'could not resolve health catalog digest' }
	$digestRef = "$Repository@$digest"
	& cosign sign --yes $digestRef
	if ($LASTEXITCODE -ne 0) { throw 'health catalog signing failed' }
	& docker buildx imagetools create --prefer-index=false --tag "$Repository`:tlc-catalog-v1" $digestRef
	if ($LASTEXITCODE -ne 0) { throw 'health catalog promotion failed' }
	Write-Output "Published signed health catalog $Repository`:tlc-catalog-v1 at $digest"
} finally {
	if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
