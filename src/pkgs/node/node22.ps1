<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

Initialize-TlcNodePackage -Major 22
$global:TlcPackageConfig.PublishEligible = $false
$global:TlcPackageConfig.PublicationBlockReason = 'Node.js 22 currently bundles npm dependencies with active HIGH/CRITICAL vulnerabilities; restore publication after an upstream patched bundle is available.'
