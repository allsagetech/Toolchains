<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'crane' -CanonicalName 'crane' -Owner 'google' -Repo 'go-containerregistry' `
	-AssetPattern '^go-containerregistry_Windows_x86_64\.tar\.gz$' -BinaryName 'crane.exe' -ArchiveType tar.gz `
	-ChecksumAssetPattern '^checksums\.txt$' -VersionArguments @('version')
