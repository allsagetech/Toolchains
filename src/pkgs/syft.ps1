<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'syft' -CanonicalName 'syft' -Owner 'anchore' -Repo 'syft' `
	-AssetPattern '^syft_[0-9.]+_windows_amd64\.zip$' -BinaryName 'syft.exe' -ArchiveType zip `
	-ChecksumAssetPattern '^syft_[0-9.]+_checksums\.txt$' -VersionArguments @('version')
