<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

Initialize-TlcNodePackage -Major 18 -LifecycleNote 'End-of-life: 2025-04-30; retained for compatibility.'
$global:TlcPackageConfig.PublishEligible = $false
$global:TlcPackageConfig.PublicationBlockReason = 'Node.js 18 is end-of-life and no longer receives upstream security fixes.'
