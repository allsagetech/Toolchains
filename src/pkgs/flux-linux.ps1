<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'flux-linux' -CanonicalName 'flux' -Owner 'fluxcd' -Repo 'flux2' `
	-AssetPattern '^flux_[0-9.]+_linux_amd64\.tar\.gz$' -BinaryName 'flux' -ArchiveType tar.gz `
	-ChecksumAssetPattern '^flux_[0-9.]+_checksums\.txt$' -VersionArguments @('--version') -Linux
