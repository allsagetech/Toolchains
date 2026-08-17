<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)]
	[ValidatePattern('^[a-z0-9._/-]+@sha256:[0-9a-f]{64}$')]
	[string]$DigestRef,

	[Parameter(Mandatory=$true)]
	[ValidatePattern('^https://')]
	[string]$CertificateIdentity,

	[Parameter(Mandatory=$true)]
	[ValidatePattern('^https://')]
	[string]$CertificateOidcIssuer,

	[string]$SbomDigestRef,

	[ValidateRange(1, 5)]
	[int]$MaxAttempts = 2,

	[ValidateRange(10, 300)]
	[int]$TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
$cosign = Get-Command cosign -CommandType Application -ErrorAction Stop

function Invoke-CosignVerification {
	param(
		[Parameter(Mandatory=$true)][string]$Description,
		[Parameter(Mandatory=$true)][string[]]$Arguments,
		[string]$OutputPath,
		[switch]$AllowFailure
	)

	$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
	$ownsOutput = [string]::IsNullOrWhiteSpace($OutputPath)
	$outputFile = if ($ownsOutput) { Join-Path $tempRoot "cosign-verification-$([guid]::NewGuid().ToString('N')).json" } else { $OutputPath }
	if ([IO.File]::Exists($outputFile)) { [IO.File]::Delete($outputFile) }
	$effectiveArguments = @($Arguments[0], '--output-file', $outputFile) + @($Arguments | Select-Object -Skip 1)
	try {
		for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
			Write-Host "$Description (attempt $attempt/$MaxAttempts)"
			$startInfo = [Diagnostics.ProcessStartInfo]::new()
			$startInfo.FileName = $cosign.Source
			$startInfo.UseShellExecute = $false
			$startInfo.CreateNoWindow = $true
			foreach ($argument in $effectiveArguments) { [void]$startInfo.ArgumentList.Add($argument) }

			# Keep diagnostic handles inherited while directing Cosign's potentially large
			# verified JSON payload to disk. This avoids both redirected-stream child hangs
			# on Windows and runner-log backpressure for large SBOM attestations on Linux.
			$process = [Diagnostics.Process]::new()
			$process.StartInfo = $startInfo
			try {
				if (-not $process.Start()) { throw "could not start $($cosign.Source)" }
				$finished = $process.WaitForExit($TimeoutSeconds * 1000)
				if (-not $finished) {
					try { $process.Kill() } catch { Write-Verbose "Cosign process termination reported: $($_.Exception.Message)" }
					if (-not $process.WaitForExit(5000)) {
						throw "$Description could not terminate its timed-out process."
					}
				}

				if (-not $finished) {
					$reason = "timed out after $TimeoutSeconds seconds"
				} elseif ($process.ExitCode -eq 0) {
					return $true
				} else {
					$reason = "failed with exit code $($process.ExitCode)"
				}
			} finally {
				$process.Dispose()
			}

			if ($attempt -lt $MaxAttempts) {
				$delay = [math]::Pow(2, $attempt)
				Write-Warning "$Description $reason; retrying in $delay seconds."
				Start-Sleep -Seconds $delay
			}
		}

		if ($AllowFailure) { return $false }
		throw "$Description $reason after $MaxAttempts attempts."
	} finally {
		if ($ownsOutput -and [IO.File]::Exists($outputFile)) { [IO.File]::Delete($outputFile) }
	}
}

$identityArguments = @(
	'--offline', '--timeout', '30s',
	'--certificate-identity', $CertificateIdentity,
	'--certificate-oidc-issuer', $CertificateOidcIssuer
)
$null = Invoke-CosignVerification -Description 'Published signature verification' -Arguments (@('verify') + $identityArguments + $DigestRef)

$sbomReferenceType = 'https://allsagetech.com/toolchains/attestations/sbom-reference/v1'
$usesReferenceAttestation = -not [string]::IsNullOrWhiteSpace($SbomDigestRef)
if ($usesReferenceAttestation -and $SbomDigestRef -notmatch '^[a-z0-9._/-]+@sha256:[0-9a-f]{64}$') {
	throw 'SBOM digest reference is invalid.'
}
if (-not $usesReferenceAttestation) {
	$legacySbomVerified = Invoke-CosignVerification `
		-Description 'Published SPDX attestation verification' `
		-Arguments (@('verify-attestation', '--type', 'spdxjson') + $identityArguments + $DigestRef) `
		-AllowFailure
	$usesReferenceAttestation = -not $legacySbomVerified
}

if ($usesReferenceAttestation) {
	$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
	$referenceOutput = Join-Path $tempRoot "cosign-sbom-reference-$([guid]::NewGuid().ToString('N')).json"
	try {
		$null = Invoke-CosignVerification `
			-Description 'Published SBOM reference attestation verification' `
			-Arguments (@('verify-attestation', '--type', $sbomReferenceType) + $identityArguments + $DigestRef) `
			-OutputPath $referenceOutput

		$imageParts = @($DigestRef -split '@sha256:', 2)
		$imageRepository = $imageParts[0]
		$imageDigest = $imageParts[1]
		$verifiedReferences = @()
		foreach ($line in @(Get-Content -LiteralPath $referenceOutput)) {
			if ([string]::IsNullOrWhiteSpace($line)) { continue }
			try {
				$envelope = $line | ConvertFrom-Json
				$statementJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$envelope.payload))
				$statement = $statementJson | ConvertFrom-Json
			} catch {
				throw "Verified SBOM reference output was malformed: $($_.Exception.Message)"
			}

			if ([string]$statement.predicateType -cne $sbomReferenceType) { continue }
			$matchingSubject = @($statement.subject | Where-Object { [string]$_.digest.sha256 -ceq $imageDigest })
			if ($matchingSubject.Count -eq 0) { continue }
			$artifactUri = [string]$statement.predicate.sbom.artifact.uri
			if ($artifactUri -notmatch '^oci://(.+)$') { continue }
			$artifactRef = $Matches[1]
			if ($artifactRef -notmatch "^$([regex]::Escape($imageRepository))@sha256:[0-9a-f]{64}$") { continue }
			$artifactDigest = ($artifactRef -split '@sha256:', 2)[1]
			if ([string]$statement.predicate.sbom.artifact.digest.sha256 -cne $artifactDigest) { continue }
			if ([string]$statement.predicate.sbom.content.mediaType -cne 'application/spdx+json') { continue }
			if ([string]$statement.predicate.sbom.content.digest.sha256 -notmatch '^[0-9a-f]{64}$') { continue }
			if ([long]$statement.predicate.sbom.content.size -le 0) { continue }
			if ([string]$statement.predicate.sbom.content.documentNamespace -notmatch '^https://') { continue }
			$verifiedReferences += $artifactRef
		}

		$verifiedReferences = @($verifiedReferences | Select-Object -Unique)
		if ($SbomDigestRef) {
			if ($verifiedReferences -notcontains $SbomDigestRef) {
				throw "No verified SBOM reference attestation points to the expected artifact $SbomDigestRef."
			}
			$verifiedSbomDigestRef = $SbomDigestRef
		} elseif ($verifiedReferences.Count -gt 0) {
			$verifiedSbomDigestRef = $verifiedReferences[0]
		} else {
			throw 'No structurally valid SBOM reference was present in the verified attestation.'
		}

		$null = Invoke-CosignVerification `
			-Description 'Published SBOM artifact signature verification' `
			-Arguments (@('verify') + $identityArguments + $verifiedSbomDigestRef)
	} finally {
		if ([IO.File]::Exists($referenceOutput)) { [IO.File]::Delete($referenceOutput) }
	}
}

$null = Invoke-CosignVerification -Description 'Published provenance attestation verification' -Arguments (@('verify-attestation', '--type', 'slsaprovenance') + $identityArguments + $DigestRef)
