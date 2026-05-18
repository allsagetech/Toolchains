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
- `qwen3-0.6b:latest` for `Qwen/Qwen3-0.6B`
- `openai-gpt-oss-20b:latest` for `openai/gpt-oss-20b`

Model packages seed Hugging Face cache content and write `LOCAL_CODEX_MODEL_MANIFEST`, `LOCAL_CODEX_HF_CACHE_SEED`, and `LOCAL_CODEX_OFFICIAL_MODEL` into the `.tlc` environment. Set `HF_TOKEN` for private or gated Hugging Face repositories before building.

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

## Optional image signing (cosign)

When pushing packages, Toolchains can optionally sign the pushed image digest using Sigstore/cosign.

Enable signing by setting one of:

- `TLC_COSIGN_SIGN=1` (keyless signing; requires OIDC in CI)
- `TLC_COSIGN_KEY=/path/to/cosign.key` (key-based signing)
- `COSIGN_KEY=/path/to/cosign.key`

Signing occurs after `docker push` using the immutable `repo@sha256:...` digests.
