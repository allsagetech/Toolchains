<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

BeforeAll {
	$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
	. (Join-Path $script:RepoRoot 'src/main.ps1')
}

Describe 'Definition, cache, and path helpers' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-core-$([Guid]::NewGuid().ToString('n'))"
		New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
		$script:OldPkgRoot = $env:TLC_PKG_ROOT
		$script:OldCacheRoot = $env:TLC_CACHE_ROOT
		$script:OldStagingRoot = $env:TLC_STAGING_ROOT
		$env:TLC_PKG_ROOT = $script:TempRoot
		$env:TLC_CACHE_ROOT = Join-Path $script:TempRoot 'verified-cache'
		$env:TLC_STAGING_ROOT = Join-Path $script:TempRoot 'stage'
	}

	AfterEach {
		$env:TLC_PKG_ROOT = $script:OldPkgRoot
		$env:TLC_CACHE_ROOT = $script:OldCacheRoot
		$env:TLC_STAGING_ROOT = $script:OldStagingRoot
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'reads and validates package definitions' {
		$definition = '{"env":{"PATH":["${.}/bin"],"FLAG":"on"},"test":{"env":{"FLAG":"test"}}}'
		[IO.File]::WriteAllText((Join-Path $script:TempRoot '.tlc'), $definition)
		Get-TlcDefinitionJson | Should -Be $definition
		Assert-TlcDefinitionFile | Should -Be $definition
		Test-TlcToolchainDefinition -Definition ($definition | ConvertFrom-Json) | Should -BeTrue
		{ Test-TlcToolchainDefinition -Definition ([pscustomobject]@{ other = 1 }) } | Should -Throw '*missing required*env*'
		{ Test-TlcEnvMap -EnvMap @{ BAD = 42 } } | Should -Throw '*string or array*'
		{ Test-TlcEnvMap -EnvMap @{ BAD = @('ok', 42) } } | Should -Throw '*only strings*'
	}

	It 'fails closed when the definition is absent' {
		{ Get-TlcDefinitionJson } | Should -Throw '*not found*'
		{ Assert-TlcDefinitionFile } | Should -Throw '*not found*'
	}

	It 'builds deterministic cache and staging paths without process globals' {
		Get-TlcPkgRoot | Should -Be ([IO.Path]::GetFullPath($script:TempRoot))
		Get-TlcPkgPath -ChildPath 'bin/tool.exe' | Should -Be (Join-Path $script:TempRoot 'bin/tool.exe')
		Get-TlcPkgPath | Should -Be ([IO.Path]::GetFullPath($script:TempRoot))
		Get-TlcStagingPath -ChildPath 'x' | Should -Be (Join-Path $env:TLC_STAGING_ROOT 'x')
		$first = Get-TlcCachePathForUri -Uri 'https://example.test/tool' -Extension 'zip'
		$second = Get-TlcCachePathForUri -Uri 'https://example.test/tool' -Extension '.zip'
		$first | Should -Be $second
		$first | Should -Match '[0-9a-f]{64}\.zip$'
		Test-Path -LiteralPath $env:TLC_CACHE_ROOT -PathType Container | Should -BeTrue
		Get-TlcPkgUri | Should -Match '^file:///'
	}

	It 'canonicalizes path lists and rejects parent traversal' {
		$inside = Join-Path $script:TempRoot 'bin'
		$result = ConvertTo-TlcCanonicalPathList -Value "$inside;relative/bin;" -ContainedRoot $script:TempRoot
		$result | Should -Match ([regex]::Escape([IO.Path]::GetFullPath($inside)))
		$result | Should -Match 'relative/bin'
		{ ConvertTo-TlcCanonicalPathList -Value '../outside' -ContainedRoot $script:TempRoot } | Should -Throw '*parent traversal*'
		ConvertTo-TlcCanonicalPathList -Value $null | Should -BeNullOrEmpty
	}
}

Describe 'Local execution environment' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-exec-$([Guid]::NewGuid().ToString('n'))"
		New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
		$script:OldPkgRoot = $env:TLC_PKG_ROOT
		$script:OldProbe = $env:TLC_TEST_PROBE
		$env:TLC_PKG_ROOT = $script:TempRoot
		$env:TLC_TEST_PROBE = 'original'
	}

	AfterEach {
		$env:TLC_PKG_ROOT = $script:OldPkgRoot
		$env:TLC_TEST_PROBE = $script:OldProbe
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'applies a named config and restores the environment' {
		[IO.File]::WriteAllText((Join-Path $script:TempRoot '.tlc'), '{"env":{"TLC_TEST_PROBE":"base"},"ci":{"env":{"TLC_TEST_PROBE":"${.}/ci","EXTRA":["one","two"]}}}')
		$observed = Invoke-TlcLocalExec -Spec 'fixture < ci' -Block { "$env:TLC_TEST_PROBE|$env:EXTRA" }
		$observed | Should -Be "$script:TempRoot/ci|one$([IO.Path]::PathSeparator)two"
		$env:TLC_TEST_PROBE | Should -Be 'original'
		Test-Path Env:EXTRA | Should -BeFalse
	}

	It 'rejects missing and malformed configs and unsupported wrapper verbs' {
		[IO.File]::WriteAllText((Join-Path $script:TempRoot '.tlc'), '{"env":{},"bad":{}}')
		{ Invoke-TlcLocalExec -Spec 'fixture < missing' -Block {} } | Should -Throw '*config not found*'
		{ Invoke-TlcLocalExec -Spec 'fixture < bad' -Block {} } | Should -Throw '*missing required*env*'
		{ Toolchain build fixture {} } | Should -Throw '*only supports*exec*'
	}

	It 'expands string arrays and rejects non-string values' {
		Expand-TlcEnvValue -Value '${.}/bin' -PkgRoot $script:TempRoot | Should -Be "$script:TempRoot/bin"
		$nestedPkgRoot = Join-Path $script:TempRoot 'pkg'
		Expand-TlcEnvValue -Value '${.}' -PkgRoot $nestedPkgRoot | Should -BeExactly $nestedPkgRoot
		@(Expand-TlcEnvValue -Value @('${.}/a', $null, '${.}/b') -PkgRoot $script:TempRoot).Count | Should -Be 2
		{ Expand-TlcEnvValue -Value 7 -PkgRoot $script:TempRoot } | Should -Throw '*string or array*'
		{ Expand-TlcEnvValue -Value @('ok', 7) -PkgRoot $script:TempRoot } | Should -Throw '*only strings*'
		ConvertTo-TlcHashtable -InputObject $null | Should -BeNullOrEmpty
		$converted = ConvertTo-TlcHashtable -InputObject @{ nested = [pscustomobject]@{ values = @('one', 'two') } }
		$converted.nested.values[1] | Should -Be 'two'
	}
}

Describe 'Package descriptor isolation and policy' {
	BeforeEach {
		$script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) "toolchains-runtime-$([Guid]::NewGuid().ToString('n'))"
		New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
		$script:OldPkgRoot = $env:TLC_PKG_ROOT
		$script:OldRuntimeEvidence = $env:TLC_RUNTIME_EVIDENCE
		$env:TLC_PKG_ROOT = Join-Path $script:TempRoot 'pkg'
		$env:TLC_RUNTIME_EVIDENCE = Join-Path $script:TempRoot 'runtime-evidence.json'
		New-Item -ItemType Directory -Path $env:TLC_PKG_ROOT -Force | Out-Null
	}

	AfterEach {
		Clear-TlcPackageScript
		$env:TLC_PKG_ROOT = $script:OldPkgRoot
		$env:TLC_RUNTIME_EVIDENCE = $script:OldRuntimeEvidence
		Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'loads batches in one isolated runtime without leaking state' {
		$paths = @((Join-Path $script:RepoRoot 'src/pkgs/dependabot.ps1'), (Join-Path $script:RepoRoot 'src/pkgs/git-linux.ps1'))
		$descriptors = @(Read-TlcPackageDescriptors -Path $paths)
		$descriptors.Count | Should -Be 2
		$descriptors[0].Config.Name | Should -Be 'dependabot'
		$descriptors[1].Config.Name | Should -Be 'git-linux'
		Get-Variable TlcPackageConfig -Scope Global -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
		Get-Command Install-TlcPackage -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
	}

	It 'defines yq as one integrity-checked cross-platform package family' {
		$paths = @(
			(Join-Path $script:RepoRoot 'src/pkgs/yq.ps1'),
			(Join-Path $script:RepoRoot 'src/pkgs/yq-linux.ps1')
		)
		$descriptors = @(Read-TlcPackageDescriptors -Path $paths)
		$descriptors.Count | Should -Be 2
		$descriptors[0].Config.Name | Should -Be 'yq'
		$descriptors[0].Config.CanonicalName | Should -Be 'yq'
		$descriptors[0].Config.Platform | Should -Be 'windows/amd64'
		$descriptors[1].Config.Name | Should -Be 'yq-linux'
		$descriptors[1].Config.CanonicalName | Should -Be 'yq'
		$descriptors[1].Config.Platform | Should -Be 'linux/amd64'
	}

	It 'runs a complete lifecycle in the isolated runtime' {
		$descriptor = Join-Path $script:TempRoot 'fixture.ps1'
		[IO.File]::WriteAllText($descriptor, @'
$global:TlcPackageConfig = @{ Name = 'fixture'; Nonce = $true; Version = '1.2.3'; UpToDate = $false }
function global:Install-TlcPackage { Write-TlcVars @{ env = @{ FIXTURE = '${.}/bin' } }; $global:TlcPackageConfig.UpToDate = $false }
function global:Test-TlcPackageInstall { if (-not (Test-Path (Join-Path (Get-TlcPkgRoot) '.tlc'))) { throw 'missing definition' } }
function global:Invoke-DockerPush {
	param($Name, $Version, $Config)
	[IO.File]::WriteAllText($env:TLC_RUNTIME_EVIDENCE, (@{ Name = $Name; Version = $Version; ConfigName = $Config.Name } | ConvertTo-Json -Compress))
}
'@)
		$config = Invoke-TlcPackageLifecycle -Path $descriptor -Force -Publish
		$config.Name | Should -Be 'fixture'
		$config.UpToDate | Should -BeFalse
		Test-Path -LiteralPath (Join-Path $env:TLC_PKG_ROOT '.tlc') | Should -BeTrue
		$evidence = Get-Content -LiteralPath $env:TLC_RUNTIME_EVIDENCE -Raw | ConvertFrom-Json
		$evidence.Name | Should -Be 'fixture'
		$evidence.Version | Should -Be '1.2.3'
		$evidence.ConfigName | Should -Be 'fixture'
		Get-Variable TlcPackageConfig -Scope Global -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
	}

	It 'passes immutable image build inputs through the isolated runtime' {
		$descriptor = Join-Path $script:TempRoot 'image-fixture.ps1'
		[IO.File]::WriteAllText($descriptor, @'
$global:TlcPackageConfig = @{ Name = 'descriptor-name'; Dockerfile = 'Dockerfile.layered' }
function global:Install-TlcPackage {}
function global:Test-TlcPackageInstall {}
function global:Invoke-DockerBuild {
	param($Tag, $PkgName, $PkgVersion, $DockerfileName, $Config)
	[IO.File]::WriteAllText($env:TLC_RUNTIME_EVIDENCE, (@{
		Tag = $Tag
		PkgName = $PkgName
		PkgVersion = $PkgVersion
		DockerfileName = $DockerfileName
		ConfigName = $Config.Name
		ConfigVersion = $Config.Version
	} | ConvertTo-Json -Compress))
}
'@)

		$imageRef = 'ghcr.io/allsagetech/fixture@sha256:0123456789abcdef'
		Invoke-TlcPackageImageBuild -Path $descriptor -ImageRef $imageRef -Name 'runtime-name' -Version '9.8.7'
		$evidence = Get-Content -LiteralPath $env:TLC_RUNTIME_EVIDENCE -Raw | ConvertFrom-Json
		$evidence.Tag | Should -Be $imageRef
		$evidence.PkgName | Should -Be 'runtime-name'
		$evidence.PkgVersion | Should -Be '9.8.7'
		$evidence.DockerfileName | Should -Be 'Dockerfile.layered'
		$evidence.ConfigName | Should -Be 'runtime-name'
		$evidence.ConfigVersion | Should -Be '9.8.7'
	}

	It 'closes failed runtimes and validates publication policy branches' {
		$bad = Join-Path $script:TempRoot 'bad.ps1'
		[IO.File]::WriteAllText($bad, '$global:TlcPackageConfig = @{ Name = ''bad'' }')
		{ Read-TlcPackageDescriptor -Path $bad } | Should -Throw '*failed to load*'
		(Get-TlcPackagePublicationState -Config @{ Name = 'ok' }).PublishEligible | Should -BeTrue
		$unverified = Get-TlcPackagePublicationState -Config @{ Name = 'bad'; VerifiedDownloads = $false; UnverifiedDownloadReason = 'no digest' }
		$unverified.PublishEligible | Should -BeFalse
		$unverified.QuarantineReason | Should -Be 'no digest'
		$blocked = Get-TlcPackagePublicationState -Config @{ Name = 'bad'; PublishEligible = $false; PublicationBlockReason = 'scan finding' }
		$blocked.QuarantineReason | Should -Be 'scan finding'
		{ Get-TlcPackagePublicationState -Config $null } | Should -Throw '*configuration is not loaded*'
	}
}

Describe 'Catalog performance budget' {
	It 'loads the complete descriptor catalog within its CI budget' {
		$budget = if ($env:TOOLCHAINS_CATALOG_BUDGET_MS) { [int]$env:TOOLCHAINS_CATALOG_BUDGET_MS } else { 5000 }
		$paths = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'src/pkgs') -Recurse -File -Filter '*.ps1' | Sort-Object FullName | ForEach-Object FullName)
		$stopwatch = [Diagnostics.Stopwatch]::StartNew()
		$descriptors = @(Read-TlcPackageDescriptors -Path $paths)
		$stopwatch.Stop()
		$descriptors.Count | Should -Be $paths.Count
		$stopwatch.ElapsedMilliseconds | Should -BeLessOrEqual $budget
	}
}
