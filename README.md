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

Package scripts can declare `TlcPackageConfig.Tier` as `tooling`, `model-small`, or `model-large`. Pull requests validate all descriptors and run secret-free Windows/Linux smoke builds for representative and changed publish-eligible packages. Pushes select directly changed package scripts and a bounded Windows/Linux or package-family smoke set when shared infrastructure changes; documentation-only pushes do not start package publication jobs. On `main`, selected tooling and small-model packages are eligible. Scheduled runs retain the complete enabled inventory sweep. Manual runs publish one package by name or path unless `full_inventory` is explicitly enabled, and release publication is capped at eight concurrent package jobs. Large-model descriptors remain available for catalog metadata, but their publication jobs are disabled and are omitted from every workflow matrix.

After a successful or no-op release on `main`, an unprivileged job derives model package names from the explicit model tiers and passes a names-only plan to a fresh publisher job. The publisher writes a complete generation using `tlc-kind-model-v1-<generation>-<count>--<package>` tags (or `tlc-kind-model-v1-<generation>-0--empty`). Toolchain uses the highest complete generation, so partial propagation is ignored and older generations can remain safely in place. Package names may not contain the reserved `--` separator.

Category markers are untrusted discovery hints, not authorization or integrity evidence. Every marker in a generation can reuse one existing manifest digest because only its tag name carries classification. Consumers must still verify the selected package digest, signature, and provenance through the normal pull path.

Default Windows package install/test and publish jobs run on GitHub-hosted `windows-2022`.

## Local Kubernetes cluster packages

Toolchain's local cluster commands use these integrity-checked package pairs:

- `kind` on Windows and `kind-linux` on Linux
- `k3d` on Windows and `k3d-linux` on Linux
- `kubectl` on Windows and `kubectl-linux` on Linux
- `k9s` on Windows and `k9s-linux` on Linux

The kind and k3d packages are provisioned automatically when a matching cluster
provider executable is not already on `PATH`. K9s is provisioned automatically
by `toolchain k9s` when it is not already on `PATH`. Kubectl remains opt-in with
`toolchain load kubectl` (or `kubectl-linux` on Linux). Docker Engine and
Kubernetes node container images are intentionally not bundled into these
packages.

On Windows, `toolchain load docker-desktop` adds the
`docker-desktop-install` bootstrap command. Run it with no arguments for
Docker's per-user interactive installation, or use
`docker-desktop-install -Quiet -AcceptLicense` only after reviewing Docker's
Desktop [license terms](https://docs.docker.com/subscription/desktop-license/).
The Toolchains image does not redistribute the roughly 600 MB Docker
Desktop installer: the command downloads the selected release directly from
Docker and verifies its published SHA-256 and Docker Inc. Authenticode
signature before execution. Use `-AllUsers` to request the elevated all-user
installation or `-DownloadOnly` to verify the installer without running it.

`toolchain load podman` installs Podman's Windows CLI plus the networking and
SSH proxy helpers used by Podman Machine. Toolchains rebuilds them from
checksum-database-verified Go modules with its pinned patched Go toolchain; the
upstream Windows bundle is not republished while it contains HIGH findings. The
package does not modify WSL, install a system service, or create a virtual
machine. On a compatible Windows host, initialize the runtime explicitly with
`podman machine init`, then start it with `podman machine start`.

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
- `Dockerfile.linux` is used automatically on non-Windows hosts and intentionally
  uses `scratch`: ordinary package images are extracted OCI artifacts, not runtime
  containers. Model-specific Dockerfiles may still use a runtime base when needed.
- Keep package build/push workflows in this repo; consumers should only `toolchain save`/`toolchain exec` those refs.

Run local validation without building packages:

```powershell
pwsh -NoLogo -NoProfile -File ./scripts/test-toolchains.ps1
```

Package authors must follow the lifecycle, checksum, package-root, and configuration rules in [`doc/package-authoring.md`](doc/package-authoring.md). The immutable build/scan/contract/sign/promotion sequence is documented in [`doc/release-process.md`](doc/release-process.md), and self-hosted runners should follow [`doc/cache-migration.md`](doc/cache-migration.md).

The repository and workflow boundaries are summarized in [`doc/architecture.md`](doc/architecture.md). Every publication run uploads `package-health.json` and writes a per-package Actions summary so scanner infrastructure failures, vulnerability findings, and package lifecycle failures can be distinguished without opening every matrix job.

The package-definition schema and fixtures in `schema/` are a vendored copy of the versioned Toolchain contract. Validate them with `scripts/test-package-spec.ps1`; update them from a canonical checkout with `scripts/update-package-spec.ps1`. A scheduled workflow downloads the latest immutable Toolchain contract artifact and opens an automated synchronization PR when those files change.

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

Workflow matrix entries expose `verified_downloads`, `publish_eligible`, and a
`quarantine_reason`. Packages without independent publisher provenance must set
`VerifiedDownloads = $false` and a reason; packages blocked for a separate
security or lifecycle concern set `PublishEligible = $false` and a publication
block reason. Both are excluded before production builds begin. Docker, NASM,
and zstd are currently provenance-quarantined, while Node 24 is temporarily
security-quarantined until its upstream archive contains a patched npm bundle.
