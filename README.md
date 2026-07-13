# toolchains
The package building repository for [Toolchain](https://github.com/allsagetech/toolchain).

## Licensing note
- Versions released before 02-08-2026 were distributed under the MIT License (see `LICENSES/OLD-MIT.txt`).
- Versions released on or after 02-09-2026 are distributed under the Mozilla Public License 2.0 (see `LICENSE.md`).

## Local Codex Kit Linux packages

For offline Linux container runs in `local-codex-kit`, build/push these package refs from this repo:

- `git-linux:latest`

Small local model seed packages are available as separate refs so consumers can pull only what they need:

- `smollm2-135m-instruct:latest` for `HuggingFaceTB/SmolLM2-135M-Instruct`
- `smollm2-360m-instruct:latest` for `HuggingFaceTB/SmolLM2-360M-Instruct`
- `qwen2.5-0.5b-instruct:latest` for `Qwen/Qwen2.5-0.5B-Instruct`
- `qwen2.5-coder-7b-instruct:latest` for `Qwen/Qwen2.5-Coder-7B-Instruct`
- `qwen3-0.6b:latest` for `Qwen/Qwen3-0.6B`
- `openai-gpt-oss-20b:latest` for `openai/gpt-oss-20b`

Model packages seed Hugging Face cache content under `cache/hf-cache` and write `LOCAL_CODEX_MODEL_MANIFEST`, `LOCAL_CODEX_HF_CACHE_SEED`, and `LOCAL_CODEX_OFFICIAL_MODEL` into the `.tlc` environment. Generic model packages download only common model/runtime files by default; package descriptors can pass custom `AllowPatterns` when a repository needs a different file set. Generic model packages also generate layered Dockerfiles so Hugging Face refs, snapshots, and individual blobs can be cached independently by Docker. Set `HF_TOKEN` for private or gated Hugging Face repositories before building.

Package scripts can declare `TlcPackageConfig.Tier` as `tooling`, `model-small`, or `model-large`. Pull requests validate all descriptors and run secret-free Windows/Linux smoke builds for representative and changed publish-eligible packages. Pushes to `main` include tooling plus small models; schedules and manual workflow runs include large models, with large models isolated on the self-hosted `toolchains-large` runner. Pull requests never execute large-model package code on self-hosted runners.

Default Windows package install/test and publish jobs run on GitHub-hosted `windows-2022`.

Use the helper script on a Linux host/runner:

```powershell
pwsh -NoLogo -NoProfile -File ./scripts/build-local-codex-linux-packages.ps1
```

Build/test only (no push):

```powershell
pwsh -NoLogo -NoProfile -File ./scripts/build-local-codex-linux-packages.ps1 -SkipPush
```

Build/test the core Linux packages plus the small model seed packages:

```powershell
pwsh -NoLogo -NoProfile -File ./scripts/build-local-codex-linux-packages.ps1 -SkipPush -IncludeModels
```

Notes:

- `Dockerfile` is used on Windows package builds.
- `Dockerfile.linux` is used automatically on non-Windows hosts.
- Keep package build/push workflows in this repo; consumers should only `toolchain save`/`toolchain exec` those refs.

Run local validation without building packages:

```powershell
pwsh -NoLogo -NoProfile -File ./scripts/test-toolchains.ps1
```

Package authors must follow the lifecycle, checksum, package-root, and configuration rules in [`doc/package-authoring.md`](doc/package-authoring.md). The immutable build/scan/contract/sign/promotion sequence is documented in [`doc/release-process.md`](doc/release-process.md), and self-hosted runners should follow [`doc/cache-migration.md`](doc/cache-migration.md).

The package-definition schema and fixtures in `schema/` are a vendored copy of the versioned Toolchain contract. Validate them with `scripts/test-package-spec.ps1`; update them from a canonical checkout with `scripts/update-package-spec.ps1`.

See [`SECURITY.md`](SECURITY.md) for vulnerability reporting and release supply-chain requirements, and [`CHANGELOG.md`](CHANGELOG.md) for pending user-visible changes.

## Image signing (cosign)

The protected release workflow requires keyless Sigstore signing, SBOM and provenance attestations, and verification before final-tag promotion. Direct local `Invoke-DockerPush` use can also request signing with the settings below.

Enable signing by setting one of:

- `TLC_COSIGN_SIGN=1` (keyless signing; requires OIDC in CI)
- `TLC_COSIGN_KEY=/path/to/cosign.key` (key-based signing)
- `COSIGN_KEY=/path/to/cosign.key`

Signing occurs after `docker push` using the immutable `repo@sha256:...` digests.
When signing is requested, a missing `cosign` executable, an unresolved image
digest, or a signing error is fatal; publication never reports success after a
skipped signature.

## Download cache and package roots

Package scripts should use `Get-TlcPkgRoot` or `Get-TlcPkgPath` instead of a
literal `\pkg` path. `TLC_PKG_ROOT` remains the supported override for local and
CI builds. Existing caches under `<package-root>/cache` remain readable for
compatibility, but generic image builds now exclude `cache`, partial downloads,
and temporary files from their build contexts. Set `TLC_CACHE_ROOT` to a path
outside the package root for new automation; deleting the old package-local
cache is safe and forces verified downloads to be recreated.

`Invoke-TlcWebRequest` writes downloads and independently verified cache entries
atomically. Unverified downloads are never cached, and legacy trust-on-first-use
entries are discarded. Set `TLC_REQUIRE_VERIFIED_DOWNLOADS=1` in production to
reject artifact downloads that do not supply an independent upstream hash or
signature check. Package authors should pass an
upstream `ExpectedSha256` (or `ExpectedHash` plus algorithm), require a valid
Authenticode signature, or supply a `SignatureVerifier` whenever the publisher
provides that trust metadata. Cache sidecars are bookkeeping only and never
replace an upstream checksum or signature. GitHub release assets automatically
use the SHA-256 digest returned by GitHub's release API, and Node.js archives use
the release's official `SHASUMS256.txt` when installed through
`Install-BuildTool`.

Workflow matrix entries expose `verified_downloads`, `publish_eligible`, and
`unverified_download_reason`. Packages without independent publisher provenance
must set `VerifiedDownloads = $false` and a reason; they are not eligible for
production publication. NASM is currently the only quarantined package because
its Windows archive is published without a supported checksum or signature.
