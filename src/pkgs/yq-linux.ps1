<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'yq-linux' -CanonicalName 'yq' -Owner 'mikefarah' -Repo 'yq' `
	-AssetPattern '^yq_linux_amd64$' -BinaryName 'yq' -ArchiveType direct -VersionArguments @('--version') -Linux
