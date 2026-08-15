<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'cosign-linux' -CanonicalName 'cosign' -Owner 'sigstore' -Repo 'cosign' `
	-AssetPattern '^cosign-linux-amd64$' -BinaryName 'cosign' -ArchiveType direct -VersionArguments @('version') -Linux
