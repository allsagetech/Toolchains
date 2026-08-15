<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'stern' -CanonicalName 'stern' -Owner 'stern' -Repo 'stern' `
	-AssetPattern '^stern_[0-9.]+_windows_amd64\.zip$' -BinaryName 'stern.exe' -ArchiveType zip `
	-ChecksumAssetPattern '^checksums\.txt$' -VersionArguments @('--version')
