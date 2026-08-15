<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'talosctl' -CanonicalName 'talosctl' -Owner 'siderolabs' -Repo 'talos' `
	-AssetPattern '^talosctl-windows-amd64\.exe$' -BinaryName 'talosctl.exe' -ArchiveType direct `
	-ChecksumAssetPattern '^sha256sum\.txt$' -VersionArguments @('version', '--client')
