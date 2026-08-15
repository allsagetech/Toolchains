<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'trivy-linux' -CanonicalName 'trivy' -Owner 'aquasecurity' -Repo 'trivy' `
	-AssetPattern '^trivy_[0-9.]+_Linux-64bit\.tar\.gz$' -BinaryName 'trivy' -ArchiveType tar.gz `
	-ChecksumAssetPattern '^trivy_[0-9.]+_checksums\.txt$' -VersionArguments @('--version') -Linux
