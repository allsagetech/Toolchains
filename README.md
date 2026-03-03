# toolchains
The package building repository for [Toolchain](https://github.com/allsagetech/toolchain).

## Licensing note
- Versions released before 02-08-2026 were distributed under the MIT License (see `LICENSES/OLD-MIT.txt`).
- Versions released on or after 02-09-2026 are distributed under the Mozilla Public License 2.0 (see `LICENSE.md`).

## Local Codex Kit Linux packages

For offline Linux container runs in `local-codex-kit`, build/push these package refs from this repo:

- `codex-linux:latest`
- `git-linux:latest`
- `llvm-linux:latest`

Use the helper script on a Linux host/runner:

```powershell
pwsh -NoLogo -NoProfile -File ./scripts/build-local-codex-linux-packages.ps1
```

Build/test only (no push):

```powershell
pwsh -NoLogo -NoProfile -File ./scripts/build-local-codex-linux-packages.ps1 -SkipPush
```

Notes:

- `Dockerfile` is used on Windows package builds.
- `Dockerfile.linux` is used automatically on non-Windows hosts.
- Keep package build/push workflows in this repo; consumers should only `toolchain save`/`toolchain exec` those refs.

## Optional image signing (cosign)

When pushing packages, Toolchains can optionally sign the pushed image digest using Sigstore/cosign.

Enable signing by setting one of:

- `TLC_COSIGN_SIGN=1` (keyless signing; requires OIDC in CI)
- `TLC_COSIGN_KEY=/path/to/cosign.key` (key-based signing)
- `COSIGN_KEY=/path/to/cosign.key`

Signing occurs after `docker push` using the immutable `repo@sha256:...` digests.
