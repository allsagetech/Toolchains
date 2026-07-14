# Package authoring

Each script under `src/pkgs` declares `TlcPackageConfig` and implements two functions:

- `Install-TlcPackage` discovers the candidate version, compares it with registry state, and stages content only when a new immutable package is needed.
- `Test-TlcPackageInstall` exercises the staged package through the Toolchain contract.

Package scripts must not build, push, sign, or mutate registry tags. The workflow owns those transitions.

## Required lifecycle

1. Discover one immutable upstream version and its assets.
2. Set `TlcPackageConfig.Version`.
3. Set `TlcPackageConfig.UpToDate` from the registry comparison.
4. Return without installation when the version already exists.
5. Download through the common helper with an expected SHA-256 digest or verified upstream signature.
6. Stage files beneath `Get-TlcPkgRoot`; never hard-code `\pkg`, a drive letter, or a runner-specific mount.
7. Write a schema-conforming `.tlc` definition.
8. Test every named configuration and verify the reported tool version.

Use `RunsOn` and `PublishRunsOn` only when platform requirements differ from the defaults. Use `Tier` to classify `tooling`, `model-small`, or `model-large` packages. Model packages must use an Ubuntu runner. The protected release workflow derives model catalog markers only from the explicit `model-small` and `model-large` tiers; package-name heuristics are not used. Package names cannot contain `--`, which is reserved as the category-marker separator.

If an upstream publisher offers neither a cryptographic digest nor a supported signature, set `TlcPackageConfig.VerifiedDownloads = $false` and provide `UnverifiedDownloadReason`. This is a quarantine marker, not an exception: strict smoke and release jobs refuse to build or publish the package until independent provenance is available. Do not disable strict download mode to release a quarantined package.

Run `./scripts/test-toolchains.ps1` before submitting a change. Pull requests must also pass the representative Windows and Linux image smoke builds.
