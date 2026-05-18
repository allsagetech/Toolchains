<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'qwen3-0.6b'
	RunsOn = 'ubuntu-latest'
	Tier = 'model-small'
}

function global:Install-TlcPackage {
	Install-HfModelPackage @{
		Alias = 'qwen3-0.6b'
		Repo = 'Qwen/Qwen3-0.6B'
		CacheSlug = 'models--Qwen--Qwen3-0.6B'
		OfficialModel = 'Qwen/Qwen3-0.6B'
	}
}

function global:Test-TlcPackageInstall {
	Test-HfModelPackageInstall -Repo 'Qwen/Qwen3-0.6B' -CacheSlug 'models--Qwen--Qwen3-0.6B'
}

function global:Invoke-CustomDockerBuild($tag) {
	Invoke-HfModelCustomDockerBuild $tag
}
