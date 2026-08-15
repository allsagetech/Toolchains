<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'cosign' -CanonicalName 'cosign' -Owner 'sigstore' -Repo 'cosign' `
	-AssetPattern '^cosign-windows-amd64\.exe$' -BinaryName 'cosign.exe' -ArchiveType direct -VersionArguments @('version')
