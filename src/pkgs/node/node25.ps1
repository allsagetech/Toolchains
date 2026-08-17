<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

Initialize-TlcNodePackage -Major 25 -LifecycleNote 'End-of-life: 2026-06-01; retained for compatibility.'
$global:TlcPackageConfig.PublishEligible = $false
$global:TlcPackageConfig.PublicationBlockReason = 'Node.js 25 is end-of-life and no longer receives upstream security fixes.'
