<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'stern-linux' -CanonicalName 'stern' -Owner 'stern' -Repo 'stern' `
	-AssetPattern '^stern_[0-9.]+_linux_amd64\.tar\.gz$' -BinaryName 'stern' -ArchiveType tar.gz `
	-ChecksumAssetPattern '^checksums\.txt$' -VersionArguments @('--version') -Linux
