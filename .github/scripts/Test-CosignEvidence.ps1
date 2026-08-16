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
		[Parameter(Mandatory=$true)][string[]]$Arguments
	)

	for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
		Write-Host "$Description (attempt $attempt/$MaxAttempts)"
		$startInfo = [Diagnostics.ProcessStartInfo]::new()
		$startInfo.FileName = $cosign.Source
		$startInfo.UseShellExecute = $false
		$startInfo.CreateNoWindow = $true
		foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }

		# Inherit the runner's output handles. Redirected Process streams can keep a
		# terminated Windows child attached indefinitely and defeat every outer timeout.
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
				return
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

	throw "$Description $reason after $MaxAttempts attempts."
}

$identityArguments = @(
	'--offline', '--timeout', '30s',
	'--certificate-identity', $CertificateIdentity,
	'--certificate-oidc-issuer', $CertificateOidcIssuer
)
Invoke-CosignVerification -Description 'Published signature verification' -Arguments (@('verify') + $identityArguments + $DigestRef)
Invoke-CosignVerification -Description 'Published SBOM attestation verification' -Arguments (@('verify-attestation', '--type', 'spdxjson') + $identityArguments + $DigestRef)
Invoke-CosignVerification -Description 'Published provenance attestation verification' -Arguments (@('verify-attestation', '--type', 'slsaprovenance') + $identityArguments + $DigestRef)
