<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'oras-linux' -CanonicalName 'oras' -Owner 'oras-project' -Repo 'oras' `
	-AssetPattern '^oras_[0-9.]+_linux_amd64\.tar\.gz$' -BinaryName 'oras' -ArchiveType tar.gz `
	-ChecksumAssetPattern '^oras_[0-9.]+_checksums\.txt$' -VersionArguments @('version') -Linux
