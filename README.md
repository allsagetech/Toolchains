# toolchains
The package building repository for [Toolchain](https://github.com/allsagetech/toolchain).

## Licensing note
- Versions released before 02-08-2026 were distributed under the MIT License (see `LICENSES/OLD-MIT.txt`).
- Versions released on or after 02-09-2026 are distributed under the Mozilla Public License 2.0 (see `LICENSE.md`).

## Optional image signing (cosign)

When pushing packages, Toolchains can optionally sign the pushed image digest using Sigstore/cosign.

Enable signing by setting one of:

- `TLC_COSIGN_SIGN=1` (keyless signing; requires OIDC in CI)
- `TLC_COSIGN_KEY=/path/to/cosign.key` (key-based signing)
- `COSIGN_KEY=/path/to/cosign.key`

Signing occurs after `docker push` using the immutable `repo@sha256:...` digests.