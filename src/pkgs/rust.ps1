<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'rust'
}

function global:Install-TlcPackage {
	$params = @{
		Owner = 'rust-lang'
		Repo = 'rust'
		TagPattern = '^([0-9]+)\.([0-9]+)\.([0-9]+)$'
	}
	$latest = Get-GitHubTag @params
	$global:TlcPackageConfig.UpToDate = -not $latest.Version.LaterThan($global:TlcPackageConfig.Latest)
	$global:TlcPackageConfig.Version = $latest.Version.ToString()
	if ($global:TlcPackageConfig.UpToDate) {
		return
	}
	Write-Host 'setting environment variables for installation'
	foreach ($dir in @('\pkg', '\pkg\.rustup','\pkg\.cargo')) {
		New-Item -Path $dir -ItemType Directory -Force -ErrorAction Ignore | Out-Null
	}
	[System.Environment]::SetEnvironmentVariable('RUSTUP_HOME', '\pkg\.rustup')
	[System.Environment]::SetEnvironmentVariable('CARGO_HOME', '\pkg\.cargo')
	[System.Environment]::SetEnvironmentVariable('Path', "\pkg\.cargo\bin;$env:Path")
	Write-Host "Path=$env:Path"
	Write-Host 'downloading rustup-init'
	$init = "$env:Temp\rustup-init.exe"
	Invoke-TlcWebRequest -Uri 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile $init
	Write-Host "installing rust $($latest.Version)"
	& $init --version
	if ($LASTEXITCODE -ne 0) {
		throw "rustup-init version exit code $LASTEXITCODE"
	}
	& $init -v -y --no-update-default-toolchain
	if ($LASTEXITCODE -ne 0) {
		throw "rustup-init exit code $LASTEXITCODE"
	}
	Write-Host "using $((Get-Command rustup.exe).Source)"
	rustup.exe default $latest.Version
	if ($LASTEXITCODE -ne 0) {
		throw "rustup default $($latest.Version) exit code $LASTEXITCODE"
	}
	foreach ($target in @('x86_64-pc-windows-msvc')) {
		rustup.exe target add $target
		if ($LASTEXITCODE -ne 0) {
			throw "rustup target add $target exit code $LASTEXITCODE"
		}
	}
	rustup.exe toolchain install $latest.Version
	if ($LASTEXITCODE -ne 0) {
		throw "rustup toolchain install $($latest.Version) exit code $LASTEXITCODE"
	}
	Write-TlcVars @{
		env = @{
			cargo_home = '\pkg\.cargo'
			rustup_home = '\pkg\.rustup'
			path = '\pkg\.cargo\bin', (Get-ChildItem -Path '\pkg\.rustup' -Recurse -Include 'rustc.exe' | Select-Object -First 1).DirectoryName -join ';'
		}
	}
}

function global:Test-TlcPackageInstall {
	if (-not $global:TlcPackageConfig.Version) {
		throw 'missing package version'
	}
	$wantver = "rustc $($global:TlcPackageConfig.Version) "
	Toolchain exec (Get-TlcPkgUri) {
		$rustver = & rustc.exe --version
		if ($LASTEXITCODE -ne 0) {
			throw "rustc version exit code $LASTEXITCODE"
		}
		Write-Host "test rust version $rustver"
		if (-not $rustver.ToString().StartsWith($wantver)) {
			throw "wrong version $rustver (want $wantver)"
		}
		"fn main() { println!(`"Hello world`"); }" | Out-File -FilePath main.rs -Encoding utf8
		rustc.exe main.rs
		if ($LASTEXITCODE -ne 0) {
			throw "rustc exit code $LASTEXITCODE"
		}
		$out = & .\main.exe
		if ($out -ne "Hello world") {
			throw "bad program output ``$out``"
		}
		$out
	}
}
