<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'flux' -CanonicalName 'flux' -Owner 'fluxcd' -Repo 'flux2' `
	-AssetPattern '^flux_[0-9.]+_windows_amd64\.zip$' -BinaryName 'flux.exe' -ArchiveType zip `
	-ChecksumAssetPattern '^flux_[0-9.]+_checksums\.txt$' -VersionArguments @('--version')
