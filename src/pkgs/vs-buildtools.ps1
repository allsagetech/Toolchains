<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'vs-buildtools'
	BuildRevision = 1
}

$global:MSVCVersions = @(
    @{Name = 'msvc143'; Archs = @('x86', 'x64', 'amd64', 'arm', 'arm64')},
    @{Name = 'msvc142'; Ver = '14.29'; Archs = @('x86', 'x64', 'amd64')},
    @{Name = 'msvc141'; Ver = '14.16'; Archs = @('x86', 'x64', 'amd64')},
    @{Name = 'msvc140'; Ver = '14.0';  Archs = @('x86', 'x64', 'amd64', 'arm')}
)

function global:Install-TlcPackage {
    $OldPath    = $env:Path
    $VSInfo     = $null

    $VersionWanted = if ($env:GITHUB_REF_NAME -match '-([0-9]+\.[0-9]+\.[0-9]+)$') {
        [TlcSemanticVersion]::new($Matches[1])
    } else {
        $null
    }

    $releaseHistory = (Invoke-TlcWebRequest -Uri 'https://learn.microsoft.com/en-us/visualstudio/releases/2022/release-history').Content
    $VSInfo = Get-TlcVisualStudioBuildToolsRelease -Content $releaseHistory -VersionWanted $VersionWanted

    if (-not $VSInfo) {
        if ($VersionWanted) {
            Write-Error "Requested Visual Studio Build Tools LTSC version $VersionWanted not found"
        }
        else {
            Write-Error 'No suitable Visual Studio Build Tools LTSC version found'
        }
        return
    }

    $TargetVersion = $VSInfo.Version
	$PackageVersion = [TlcSemanticVersion]::new((Add-TlcPackagingRevision -Version $TargetVersion.ToString() -Revision ([int]$TlcPackageConfig.BuildRevision)))

    if ($TlcPackageConfig.Latest) {
		$TlcPackageConfig.UpToDate = -not $PackageVersion.LaterThan($TlcPackageConfig.Latest)
    }
    else {
        $TlcPackageConfig.UpToDate = $false
    }

    $TlcPackageConfig.Version = $PackageVersion.ToString()

    if ($TlcPackageConfig.UpToDate) {
        return
    }

    Write-Output "Installing Visual Studio Build Tools v$($TlcPackageConfig.Version)..."
	Invoke-TlcWebRequest -Uri $VSInfo.URI -OutFile 'vs_buildtools.exe' -RequireValidAuthenticodeSignature
    $Options = @(
        "--add Microsoft.VisualStudio.Workload.VCTools",
        "--add Microsoft.VisualStudio.Component.VC.ASAN",
        "--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "--add Microsoft.VisualStudio.Component.VC.Tools.ARM",
        "--add Microsoft.VisualStudio.Component.VC.Tools.ARM64",
        "--add Microsoft.VisualStudio.Component.VC.Tools.ARM64EC",
        "--add Microsoft.VisualStudio.ComponentGroup.VC.Tools.142.x86.x64",
        "--add Microsoft.VisualStudio.Component.VC.v141.x86.x64",
        "--add Microsoft.VisualStudio.Component.VC.140"
    )
    $setup = Start-Process ./vs_buildtools.exe "--quiet --wait --norestart --nocache --installPath `"%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools`" $($Options -join ' ')" -Wait -PassThru
    if ($setup.ExitCode -NotIn @(0, 3010)) {
        Write-Error "Visual Studio Build Tools setup failed with error code $($setup.ExitCode)"
    }
    Write-Output 'Done Installing'

	$pkgRoot = Get-TlcPkgRoot
	New-Item -ItemType Directory -Path $pkgRoot -Force | Out-Null
	$packageRoots = @(
		"${env:ProgramFiles(x86)}\Microsoft Visual Studio*"
		"${env:ProgramFiles(x86)}\Microsoft SDKs"
		"${env:ProgramFiles(x86)}\Windows Kits"
	)
	Move-Item -Path $packageRoots -Destination $pkgRoot

    [System.IO.File]::WriteAllText((Get-TlcPkgPath 'Microsoft Visual Studio\2022\BuildTools\Common7\Tools\vsdevcmd\core\winsdk.bat'),
        [System.IO.File]::ReadAllText((Get-TlcPkgPath 'Microsoft Visual Studio\2022\BuildTools\Common7\Tools\vsdevcmd\core\winsdk.bat')).
        Replace('reg query "%1\Microsoft\Microsoft SDKs\Windows\v10.0" /v "InstallationFolder"', 'echo InstallationFolder X %~dp0..\..\..\..\..\..\..\Windows Kits\10\').
        Replace('reg query "%1\Microsoft\Microsoft SDKs\Windows\v8.1" /v "InstallationFolder"', 'echo InstallationFolder X %~dp0..\..\..\..\..\..\..\Windows Kits\8.1\').
        Replace('reg query "%1\Microsoft\Windows Kits\Installed Roots" /v "KitsRoot10"', 'echo KitsRoot10 X %~dp0..\..\..\..\..\..\..\Windows Kits\10\'))

    [System.IO.File]::WriteAllText((Get-TlcPkgPath 'Microsoft Visual Studio\2022\BuildTools\Common7\Tools\vsdevcmd\ext\vcvars\vcvars140.bat'),
        [System.IO.File]::ReadAllText((Get-TlcPkgPath 'Microsoft Visual Studio\2022\BuildTools\Common7\Tools\vsdevcmd\ext\vcvars\vcvars140.bat')).
        Replace('reg query "%1\Microsoft\VisualStudio\SxS\VC7" /v "14.0"', 'echo 14.0 X %~dp0..\..\..\..\..\..\..\..\Microsoft Visual Studio 14.0\VC\'))

	$unusedAncillaryPaths = @(
		'Microsoft SDKs\NuGetPackages\coverlet.collector'
		'Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\Identity\ServiceHub\IdentityService'
		'Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\TestWindow'
		'Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\VBCSharp\LanguageServices\InteractiveHost'
	)
	foreach ($relativePath in $unusedAncillaryPaths) {
		$fullPath = Get-TlcPkgPath $relativePath
		if (Test-Path -LiteralPath $fullPath) { Remove-Item -LiteralPath $fullPath -Recurse -Force }
	}

    Write-Output 'Done Hacking'

    $TlcPackageVars = @{}
    foreach ($msvc in $MSVCVersions) {
        foreach ($arch in $msvc.Archs) {
            Write-Output "Evaluating variables for configuration $($msvc.name) on arch $arch"
            $vars = 'WindowsSdkBinPath', 'WindowsSdkVerBinPath', 'WindowsSDKVersion', 'VCToolsRedistDir', 'VSCMD_ARG_VCVARS_VER', 'UniversalCRTSdkDir', 'WindowsSdkDir', 'VCIDEInstallDir', 'VSCMD_ARG_HOST_ARCH', 'VSCMD_ARG_app_plat', 'VCToolsVersion', 'INCLUDE', 'EXTERNAL_INCLUDE', 'WindowsLibPath', 'VCToolsInstallDir', 'VCINSTALLDIR', 'VS170COMNTOOLS', 'LIBPATH', 'path', 'UCRTVersion', 'DevEnvDir', 'WindowsSDKLibVersion', 'LIB', 'VSCMD_VER', 'VSINSTALLDIR', 'VSCMD_ARG_TGT_ARCH', 'VisualStudioVersion'
            $pathListVars = 'WindowsSdkBinPath', 'WindowsSdkVerBinPath', 'VCToolsRedistDir', 'UniversalCRTSdkDir', 'WindowsSdkDir', 'VCIDEInstallDir', 'INCLUDE', 'EXTERNAL_INCLUDE', 'WindowsLibPath', 'VCToolsInstallDir', 'VCINSTALLDIR', 'VS170COMNTOOLS', 'LIBPATH', 'path', 'DevEnvDir', 'LIB', 'VSINSTALLDIR'
            foreach ($v in $vars) {
                Clear-Item "env:$v" -Force -ErrorAction SilentlyContinue
            }
            Write-Output 'Env Cleared'

            $path      = 'C:\windows;C:\windows\system32;C:\windows\system32\WindowsPowerShell\v1.0'
            $env:path  = $path
            $vsSetup   = "`"$((Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'VsDevCmd.bat' | Select-Object -First 1).FullName)`" $(if ($msvc.Ver) { "-vcvars_ver=$($msvc.Ver)" }) -arch=$arch -host_arch=amd64"
            Write-Output 'Starting Dev Setup'
            $vsenv     = cmd /S /C "$vsSetup && set"
            $vsenv.Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries) |
                ForEach-Object {
                    $s = $_.Split('=')
                    if ($s.count -eq 2) {
                        Set-Item "env:$($s[0])" $s[1]
                        if ($s[1].Length -gt 2000) {
                            Write-Warning "Long environment variable detected: $($s[0])"
                        }
                    }
                }

            $map = @{}
            foreach ($var in $vars) {
                $value = Get-Item "env:$var" -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.value.Replace("${env:ProgramFiles(x86)}", (Get-TlcPkgRoot)) }
                if ($null -ne $value -and $pathListVars -contains $var) {
                    $value = ConvertTo-TlcCanonicalPathList -Value $value -ContainedRoot (Get-TlcPkgRoot)
                }
                $map.$var = $value
                Write-Output "  $var=$($map.$var)"
            }
            $map.path = $map.path.Replace($path, '')

            if ($MSVCVersions.IndexOf($msvc) -eq 0) {
                $TlcPackageVars.$arch = @{ env = $map }
                if ($msvc.Archs.IndexOf($arch) -eq 0) {
                    $TlcPackageVars.env = $map
                }
            }
            elseif ($msvc.Archs.IndexOf($arch) -eq 0) {
                $TlcPackageVars."$($msvc.name)" = @{ env = $map }
            }
            $TlcPackageVars."$($msvc.name)-$arch" = @{ env = $map }
        }
    }

    Get-ChildItem (Get-TlcPkgPath 'Windows Kits') '10.0.*' -Recurse -Exclude $TlcPackageVars.env.UCRTVersion |
        Remove-Item -Recurse -Force

    Write-TlcVars $TlcPackageVars
    $env:path = $OldPath
}

function global:Test-TlcPackageInstall {
	foreach ($relativePath in @(
		'Microsoft SDKs\NuGetPackages\coverlet.collector'
		'Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\Identity\ServiceHub\IdentityService'
		'Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\TestWindow'
		'Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\VBCSharp\LanguageServices\InteractiveHost'
	)) {
		if (Test-Path -LiteralPath (Get-TlcPkgPath $relativePath)) { throw "Unused vulnerable Visual Studio component remains: $relativePath" }
	}

    Write-Host '--- Testing config default ---'
    Toolchain exec (Get-TlcPkgUri) {
        $testC = Join-Path $env:TEMP 'tlc_msvc_smoketest.c'
        Set-Content -Path $testC -Value 'int main(void){return 0;}' -Encoding ascii
		$compiler = Get-TlcApplicationPath -Name 'cl.exe'
		Invoke-TlcNativeCommand -FilePath $compiler -ArgumentList @('/nologo', '/Bv', '/c', $testC) `
			-FailureMessage 'Default MSVC compiler smoke test failed'
    }

    foreach ($msvc in $MSVCVersions) {
        foreach ($arch in $msvc.Archs) {
            Write-Host "--- Testing config $($msvc.name)-$arch ---"
            Toolchain exec "$(Get-TlcPkgUri)<$($msvc.name)-$arch" {
                $testC = Join-Path $env:TEMP "tlc_msvc_smoketest_$($env:VSCMD_ARG_VCVARS_VER)_$($env:VSCMD_ARG_TGT_ARCH).c"
                Set-Content -Path $testC -Value 'int main(void){return 0;}' -Encoding ascii
				$compiler = Get-TlcApplicationPath -Name 'cl.exe'
				Invoke-TlcNativeCommand -FilePath $compiler -ArgumentList @('/nologo', '/Bv', '/c', $testC) `
					-FailureMessage "MSVC compiler smoke test failed for $($msvc.name)-$arch"
            }
        }
    }
}

function global:Invoke-CustomDockerBuild($tag, [string[]]$labels) {
	$pkgRoot = Get-TlcPkgRoot
	$dockerfile = Join-Path $pkgRoot 'Dockerfile.vs-buildtools'
	Copy-Item Dockerfile -Destination $dockerfile
	Set-TlcPackageDockerignore -PkgRoot $pkgRoot
	$dockerArguments = @('build', '-f', $dockerfile, '-t', $tag)
	foreach ($label in $labels) { $dockerArguments += @('--label', $label) }
	$dockerArguments += $pkgRoot
	$docker = Get-TlcApplicationPath -Name 'docker'
	Invoke-TlcNativeCommand -FilePath $docker -ArgumentList $dockerArguments `
		-FailureMessage "docker build failed for $tag"
}
