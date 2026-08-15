<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'syft-linux' -CanonicalName 'syft' -Owner 'anchore' -Repo 'syft' `
	-AssetPattern '^syft_[0-9.]+_linux_amd64\.tar\.gz$' -BinaryName 'syft' -ArchiveType tar.gz `
	-ChecksumAssetPattern '^syft_[0-9.]+_checksums\.txt$' -VersionArguments @('version') -Linux
