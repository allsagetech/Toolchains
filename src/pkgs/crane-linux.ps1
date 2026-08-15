<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'crane-linux' -CanonicalName 'crane' -Owner 'google' -Repo 'go-containerregistry' `
	-AssetPattern '^go-containerregistry_Linux_x86_64\.tar\.gz$' -BinaryName 'crane' -ArchiveType tar.gz `
	-ChecksumAssetPattern '^checksums\.txt$' -VersionArguments @('version') -Linux
