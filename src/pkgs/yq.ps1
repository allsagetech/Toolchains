<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'yq' -CanonicalName 'yq' -Owner 'mikefarah' -Repo 'yq' `
	-AssetPattern '^yq_windows_amd64\.exe$' -BinaryName 'yq.exe' -ArchiveType direct -VersionArguments @('--version')
