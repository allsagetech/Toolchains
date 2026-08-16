<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

BeforeAll {
	. "$PSScriptRoot\test-toolchains.ps1"
}

Describe 'Toolchains repository validation' {
	It 'parses every PowerShell source file' { Test-PowerShellSyntax }
	It 'uses an explicit user agent for web requests' { Test-WebRequestUserAgent }
	It 'validates every package descriptor' { Test-PackageScripts }
	It 'validates model category markers' { Test-ModelCategoryMarkers }
	It 'validates the package contract schema' { & "$PSScriptRoot\test-package-spec.ps1" }
	It 'validates Hugging Face helpers' { Test-HuggingFaceHelpers }
	It 'validates layered Hugging Face images' { Test-HuggingFaceLayeredDockerfile }
	It 'validates upstream metadata parsers' { Test-UpstreamMetadataParsers }
	It 'validates platform-index migration' { Test-PlatformIndexMigrationPlan }
	It 'validates workflow runner defaults' { Test-WorkflowRunnerDefaults }
	It 'validates production-readiness policies' { Test-ProductionReadinessPolicies }
	It 'validates atomic verified downloads' { Test-AtomicVerifiedDownloads }
	It 'validates package lifecycle transitions' { Test-PackageLifecycleStateTransitions }
	It 'rejects malformed semantic versions' { Test-SemanticVersionValidation }
	It 'keeps the generated package inventory current' { Test-PackageInventory }
}
