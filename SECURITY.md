# Security policy

## Reporting a vulnerability

Do not open a public issue for an undisclosed package or release-pipeline vulnerability. Use GitHub's private vulnerability-reporting flow for the Toolchains repository and include the affected package, published digest, upstream source, and a minimal reproducer.

## Package supply-chain requirements

Package sources, release metadata, downloaded installers, build caches, and base images are untrusted inputs. Production packages must follow these rules:

- discover a candidate immutable version before installation and compare it with registry state;
- verify every downloaded executable or archive against an expected SHA-256 digest or an equivalent upstream signature;
- keep download caches, credentials, temporary files, and build metadata outside the final image;
- install and test without publishing; only the release orchestrator may push or sign;
- build once, scan and contract-test that exact image digest, and promote the same digest;
- fail the release if required signing, scanning, provenance, or compatibility checks cannot run.

The package contract and release procedure are documented in [package authoring](doc/package-authoring.md) and [release process](doc/release-process.md).
