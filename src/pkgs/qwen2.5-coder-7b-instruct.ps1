<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'qwen2.5-coder-7b-instruct'
	RunsOn = 'ubuntu-latest'
	Tier = 'model-large'
}

function global:Install-TlcPackage {
	Install-HfModelPackage @{
		Alias = 'qwen2.5-coder-7b-instruct'
		Repo = 'Qwen/Qwen2.5-Coder-7B-Instruct'
		CacheSlug = 'models--Qwen--Qwen2.5-Coder-7B-Instruct'
		OfficialModel = 'Qwen/Qwen2.5-Coder-7B-Instruct'
	}
}

function global:Test-TlcPackageInstall {
	Test-HfModelPackageInstall -Repo 'Qwen/Qwen2.5-Coder-7B-Instruct' -CacheSlug 'models--Qwen--Qwen2.5-Coder-7B-Instruct'
}

function global:Invoke-CustomDockerBuild($tag) {
	Invoke-HfModelCustomDockerBuild $tag
}
