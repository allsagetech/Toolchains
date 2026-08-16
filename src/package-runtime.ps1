<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function Open-TlcPackageRuntime {
	[CmdletBinding()]
	param([Parameter(Mandatory=$true)][string]$Path)

	$resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
	$mainPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'main.ps1') -ErrorAction Stop).Path
	$sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
	# Descriptor files are application inputs selected by this repository, not
	# user-invoked scripts. Keep their execution-policy exception inside the
	# disposable runtime so the caller's process policy remains unchanged.
	if ($IsWindows -or $env:OS -eq 'Windows_NT') {
		$sessionState.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
	}
	$runspace = [RunspaceFactory]::CreateRunspace($sessionState)
	$runspace.Open()
	$runspace.SessionStateProxy.SetVariable('TlcRuntimeMainPath', $mainPath)
	$runspace.SessionStateProxy.SetVariable('TlcRuntimePackagePath', $resolvedPath)

	$pipeline = [PowerShell]::Create()
	$pipeline.Runspace = $runspace
	try {
		$null = $pipeline.AddScript(@'
$ErrorActionPreference = 'Stop'
. $TlcRuntimeMainPath
Clear-TlcPackageScript
& $TlcRuntimePackagePath
Test-TlcPackageScript
'@)
		$null = $pipeline.Invoke()
		if ($pipeline.HadErrors) {
			$message = ($pipeline.Streams.Error | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
			throw "Package descriptor failed to load in its isolated runtime: $message"
		}

		return [pscustomobject]@{
			Path = $resolvedPath
			Runspace = $runspace
		}
	} catch {
		$message = if ($pipeline.Streams.Error.Count -gt 0) {
			($pipeline.Streams.Error | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
		} else {
			$_.Exception.Message
		}
		$runspace.Dispose()
		throw "Package descriptor failed to load in its isolated runtime: $message"
	} finally {
		$pipeline.Dispose()
	}
}

function Close-TlcPackageRuntime {
	[CmdletBinding()]
	param([Parameter(Mandatory=$true)][object]$Runtime)

	if ($Runtime.Runspace) {
		$Runtime.Runspace.Dispose()
	}
}

function Invoke-TlcPackageRuntimeCommand {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][object]$Runtime,
		[Parameter(Mandatory=$true)][scriptblock]$Command
	)

	$pipeline = [PowerShell]::Create()
	$pipeline.Runspace = $Runtime.Runspace
	try {
		$null = $pipeline.AddScript($Command.ToString())
		$output = @($pipeline.Invoke())
		if ($pipeline.HadErrors) {
			$message = ($pipeline.Streams.Error | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
			throw "Package runtime command failed: $message"
		}
		return $output
	} finally {
		$pipeline.Dispose()
	}
}

function Copy-TlcPackageRuntimeConfig {
	[CmdletBinding()]
	param([Parameter(Mandatory=$true)][object]$Runtime)

	$source = $Runtime.Runspace.SessionStateProxy.GetVariable('TlcPackageConfig')
	if (-not $source) { throw 'Package runtime did not expose a configuration.' }
	$copy = [ordered]@{}
	foreach ($key in $source.Keys) { $copy[$key] = $source[$key] }
	return $copy
}

function Read-TlcPackageDescriptor {
	[CmdletBinding()]
	param([Parameter(Mandatory=$true)][string]$Path)
	return @(Read-TlcPackageDescriptors -Path @($Path))[0]
}

function Read-TlcPackageDescriptors {
	[CmdletBinding()]
	param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string[]]$Path)

	$runtime = Open-TlcPackageRuntime -Path $Path[0]
	try {
		$descriptors = @()
		for ($index = 0; $index -lt $Path.Count; $index++) {
			if ($index -gt 0) {
				$resolvedPath = (Resolve-Path -LiteralPath $Path[$index] -ErrorAction Stop).Path
				$runtime.Runspace.SessionStateProxy.SetVariable('TlcRuntimePackagePath', $resolvedPath)
				Invoke-TlcPackageRuntimeCommand -Runtime $runtime -Command {
					Clear-TlcPackageScript
					& $TlcRuntimePackagePath
					Test-TlcPackageScript
				} | Out-Null
			} else {
				$resolvedPath = $runtime.Path
			}
			$descriptors += ,[pscustomobject]@{
				Path = $resolvedPath
				Config = Copy-TlcPackageRuntimeConfig -Runtime $runtime
			}
		}
		return $descriptors
	} finally {
		Close-TlcPackageRuntime -Runtime $runtime
	}
}

function Invoke-TlcPackageLifecycle {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][string]$Path,
		[switch]$Force,
		[switch]$Publish
	)

	$runtime = Open-TlcPackageRuntime -Path $Path
	try {
		$runtime.Runspace.SessionStateProxy.SetVariable('TlcRuntimeForce', [bool]$Force)
		$runtime.Runspace.SessionStateProxy.SetVariable('TlcRuntimePublish', [bool]$Publish)
		Invoke-TlcPackageRuntimeCommand -Runtime $runtime -Command {
			$global:LASTEXITCODE = 0
			Invoke-TlcInit
			if ($TlcRuntimeForce) {
				$global:TlcPackageConfig.Latest = [TlcSemanticVersion]::new()
				$global:TlcPackageConfig.Tags = @()
				$global:TlcPackageConfig.UpToDate = $false
			}
			Install-TlcPackage
			if ($LASTEXITCODE -ne 0) { throw "install package completed with exit code $LASTEXITCODE" }
			if ($TlcRuntimeForce -and $global:TlcPackageConfig.UpToDate) {
				throw 'A forced package build marked itself up-to-date without producing a package.'
			}
			if (-not $global:TlcPackageConfig.UpToDate) {
				$global:LASTEXITCODE = 0
				Test-TlcPackageInstall
				if ($LASTEXITCODE -ne 0) { throw "test package completed with exit code $LASTEXITCODE" }
				if ($TlcRuntimePublish) {
					Assert-TlcDefinitionFile | Out-Null
					Invoke-DockerPush -Name $global:TlcPackageConfig.Name -Version $global:TlcPackageConfig.Version -Config $global:TlcPackageConfig
				}
			}
		} | Out-Null

		$config = Copy-TlcPackageRuntimeConfig -Runtime $runtime
		Write-Host "toolchains: $($config.Name) v$($config.Version) is $(if ($config.UpToDate) { 'UP-TO-DATE' } else { 'OUT-OF-DATE' })"
		return $config
	} finally {
		Close-TlcPackageRuntime -Runtime $runtime
	}
}

function Invoke-TlcPackageImageBuild {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)][string]$Path,
		[Parameter(Mandatory=$true)][string]$ImageRef,
		[Parameter(Mandatory=$true)][string]$Name,
		[Parameter(Mandatory=$true)][string]$Version
	)

	$runtime = Open-TlcPackageRuntime -Path $Path
	try {
		$runtime.Runspace.SessionStateProxy.SetVariable('TlcRuntimeImageRef', $ImageRef)
		$runtime.Runspace.SessionStateProxy.SetVariable('TlcRuntimeName', $Name)
		$runtime.Runspace.SessionStateProxy.SetVariable('TlcRuntimeVersion', $Version)
		Invoke-TlcPackageRuntimeCommand -Runtime $runtime -Command {
			$global:TlcPackageConfig.Name = $TlcRuntimeName
			$global:TlcPackageConfig.Version = $TlcRuntimeVersion
			$dockerfileName = if ($global:TlcPackageConfig.Dockerfile) { [string]$global:TlcPackageConfig.Dockerfile } else { $null }
			Invoke-DockerBuild -Tag $TlcRuntimeImageRef -PkgName $TlcRuntimeName -PkgVersion $TlcRuntimeVersion -DockerfileName $dockerfileName -Config $global:TlcPackageConfig
		} | Out-Null
	} finally {
		Close-TlcPackageRuntime -Runtime $runtime
	}
}
