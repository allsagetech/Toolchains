<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'argocd' -CanonicalName 'argocd' -Owner 'argoproj' -Repo 'argo-cd' `
	-AssetPattern '^argocd-windows-amd64\.exe$' -BinaryName 'argocd.exe' -ArchiveType direct `
	-ChecksumAssetPattern '^cli_checksums\.txt$' -VersionArguments @('version', '--client')
