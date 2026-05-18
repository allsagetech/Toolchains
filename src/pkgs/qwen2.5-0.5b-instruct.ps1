<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'qwen2.5-0.5b-instruct'
	RunsOn = 'ubuntu-latest'
}

function global:Install-TlcPackage {
	Install-HfModelPackage @{
		Alias = 'qwen2.5-0.5b-instruct'
		Repo = 'Qwen/Qwen2.5-0.5B-Instruct'
		CacheSlug = 'models--Qwen--Qwen2.5-0.5B-Instruct'
		OfficialModel = 'Qwen/Qwen2.5-0.5B-Instruct'
	}
}

function global:Test-TlcPackageInstall {
	Test-HfModelPackageInstall -Repo 'Qwen/Qwen2.5-0.5B-Instruct' -CacheSlug 'models--Qwen--Qwen2.5-0.5B-Instruct'
}

function global:Invoke-CustomDockerBuild($tag) {
	Invoke-HfModelCustomDockerBuild $tag
}
