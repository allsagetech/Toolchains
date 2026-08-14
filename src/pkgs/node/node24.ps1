<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

Initialize-TlcNodePackage -Major 24
$global:TlcPackageConfig.PublishEligible = $false
$global:TlcPackageConfig.PublicationBlockReason = 'Node.js 24 currently bundles npm dependencies with active HIGH/CRITICAL vulnerabilities; restore publication after an upstream patched bundle is available.'
