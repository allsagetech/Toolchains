<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
Initialize-TlcGitHubCliPackage -Name 'trivy' -CanonicalName 'trivy' -Owner 'aquasecurity' -Repo 'trivy' `
	-AssetPattern '^trivy_[0-9.]+_windows-64bit\.zip$' -BinaryName 'trivy.exe' -ArchiveType zip `
	-ChecksumAssetPattern '^trivy_[0-9.]+_checksums\.txt$' -VersionArguments @('--version')
