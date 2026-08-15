<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'argocd-linux' -CanonicalName 'argocd' -Owner 'argoproj' -Repo 'argo-cd' `
	-AssetPattern '^argocd-linux-amd64$' -BinaryName 'argocd' -ArchiveType direct `
	-ChecksumAssetPattern '^cli_checksums\.txt$' -VersionArguments @('version', '--client') -Linux
