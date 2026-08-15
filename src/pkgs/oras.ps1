<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'oras' -CanonicalName 'oras' -Owner 'oras-project' -Repo 'oras' `
	-AssetPattern '^oras_[0-9.]+_windows_amd64\.zip$' -BinaryName 'oras.exe' -ArchiveType zip `
	-ChecksumAssetPattern '^oras_[0-9.]+_checksums\.txt$' -VersionArguments @('version')
