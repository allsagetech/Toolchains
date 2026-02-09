<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'erlang'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner        = 'erlang'
		Repo         = 'otp'
		AssetPattern = 'otp_win64_.+\.exe'
		TagPattern   = '^OTP-([0-9]+)\.([0-9]+)\.([0-9]+)\.?([0-9]+)?$'
	}
	$Asset = Get-GitHubRelease @Params
	$TlcPackageConfig.UpToDate = -not $Asset.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version  = $Asset.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}

	$installer = Join-Path $env:Temp $Asset.Name
	Invoke-TlcWebRequest -Uri $Asset.URL -OutFile $installer

	New-Item -ItemType Directory -Path '\pkg' -Force | Out-Null
	$target = (Resolve-Path '\pkg').Path

	$arguments = @('/S', "/D=$target")
	$proc = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru -NoNewWindow
	if ($proc.ExitCode -ne 0) {
		throw "Erlang installer failed with exit code $($proc.ExitCode)"
	}

	$erl = Get-ChildItem -Path $target -Recurse -Filter 'erl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
	if (-not $erl) {
		throw "Erlang install succeeded but erl.exe was not found under $target"
	}

	Write-TlcVars @{
		env = @{
			path = $erl.DirectoryName
		}
	}
}


function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell
	}
}