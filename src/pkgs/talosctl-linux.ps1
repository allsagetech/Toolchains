<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'talosctl-linux' -CanonicalName 'talosctl' -Owner 'siderolabs' -Repo 'talos' `
	-AssetPattern '^talosctl-linux-amd64$' -BinaryName 'talosctl' -ArchiveType direct `
	-ChecksumAssetPattern '^sha256sum\.txt$' -VersionArguments @('version', '--client') -Linux
