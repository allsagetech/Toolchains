<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'smollm2-135m-instruct'
	RunsOn = 'ubuntu-latest'
	Tier = 'model-small'
}

function global:Install-TlcPackage {
	Install-HfModelPackage @{
		Alias = 'smollm2-135m-instruct'
		Repo = 'HuggingFaceTB/SmolLM2-135M-Instruct'
		CacheSlug = 'models--HuggingFaceTB--SmolLM2-135M-Instruct'
		OfficialModel = 'HuggingFaceTB/SmolLM2-135M-Instruct'
	}
}

function global:Test-TlcPackageInstall {
	Test-HfModelPackageInstall -Repo 'HuggingFaceTB/SmolLM2-135M-Instruct' -CacheSlug 'models--HuggingFaceTB--SmolLM2-135M-Instruct'
}

function global:Invoke-CustomDockerBuild($tag) {
	Invoke-HfModelCustomDockerBuild $tag
}
