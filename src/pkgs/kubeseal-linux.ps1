<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'kubeseal-linux' -CanonicalName 'kubeseal' -Owner 'bitnami-labs' -Repo 'sealed-secrets' `
	-AssetPattern '^kubeseal-[0-9.]+-linux-amd64\.tar\.gz$' -BinaryName 'kubeseal' -ArchiveType tar.gz `
	-ChecksumAssetPattern '^sealed-secrets_[0-9.]+_checksums\.txt$' -VersionArguments @('--version') -Linux
