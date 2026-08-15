# Changelog

## Unreleased

### Added

- Add integrity-checked Windows and Linux packages for kind, k3d, and kubectl to support Toolchain-managed local Kubernetes clusters.
- Add checksum-verified Windows and Linux K9s packages for the `toolchain k9s` cluster UI command.
- Add a Windows Docker Desktop bootstrap package that discovers Docker's current release, downloads it directly from Docker, verifies its SHA-256 and Authenticode publisher, and keeps license acceptance explicit.
- Add Windows Podman CLI and Podman Machine helpers rebuilt from checksum-verified source modules with patched Go and `x/crypto`, with no automatic host or VM configuration.

### Security

- Verify downloaded package inputs and cache hits before execution.
- Rebuild kubectl for Windows and Linux from checksum-verified Go modules with patched Go, `x/net`, `x/sys`, and `x/text` dependencies.
- Rebuild Cue and Helm from checksum-verified Go modules with fixed `x/text` and `oras-go` dependencies, and quarantine Node 24 until its upstream npm bundle clears HIGH/CRITICAL findings.
- Exclude caches and temporary build content from published images.
- Fail closed when signing or compatibility contracts are required.
- Reduce CI permissions and secret exposure to protected release jobs.

### Changed

- Clean abandoned Docker Hub staging tags and orphaned Cosign attachments with dry-run previews, a publication safety delay, race-free release concurrency, and pagination resilient to Docker Hub's delayed tag-count refresh.
- Build ordinary Linux tool packages from `scratch` so extracted Toolchain packages contain only their intended payload instead of unrelated base-image files, vulnerabilities, hard links, and whiteouts, while contract tests inspect their stopped filesystems with a never-executed placeholder command.
- Disable large-model publication jobs and replace hanging live transparency-log lookups with offline verification of Cosign's signed Rekor bundles, inherited subprocess output, and bounded internal, process, and GitHub step deadlines.
- Make manual package publishing targeted by default, require explicit full-inventory opt-in, preserve shared runner capacity with bounded release parallelism, and bound Cosign verification with timeouts and retries.
- Route push publication jobs from changed package and asset paths, use bounded representatives for shared infrastructure, and reserve automatic complete inventory sweeps for scheduled runs.
- Normalize package `path` definitions to the case-sensitive Linux `PATH` variable during local execution.
- Prefer GitHub's bounded latest-release endpoint, fall back across releases that contain the requested asset, and avoid oversized release-history responses.
- Remove successful Docker Hub `staging-*` tags after verified promotion and periodically clean abandoned staging tags through the tag-specific API.
- Make Go source builds deterministic when a runner exposes multiple paths for the same executable.
- Limit Trivy SARIF evidence to the HIGH/CRITICAL severities enforced by publication policy.
- Install Cosign from pinned, browser-compatible release downloads with platform-specific SHA-256 verification.
- Separate package installation from build, publication, and signing.
- Promote the exact OCI artifact that passed scanning and Toolchain contracts.
- Pin the Toolchain build dependency to an immutable revision.
- Publish and validate a versioned package-definition contract corpus.
- Publish complete, generational model category markers from a names-only plan after successful or no-op main releases, with partial-propagation safety and no destructive tag cleanup.
- Gate package publication on pinned Windows/Linux scanner bootstrap checks and report scanner infrastructure separately from vulnerability findings.
- Upload machine-readable and human-readable per-package publication health summaries.
- Consolidate Node and Adoptium version families behind shared package logic.
- Prefer official GitHub or machine-readable Maven metadata and fixture-test the remaining Visual Studio release parser.
- Split shared network behavior from general package utilities and automate package-contract synchronization.
