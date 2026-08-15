<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'kubeseal' -CanonicalName 'kubeseal' -Owner 'bitnami-labs' -Repo 'sealed-secrets' `
	-AssetPattern '^kubeseal-[0-9.]+-windows-amd64\.tar\.gz$' -BinaryName 'kubeseal.exe' -ArchiveType tar.gz `
	-ChecksumAssetPattern '^sealed-secrets_[0-9.]+_checksums\.txt$' -VersionArguments @('--version')
