# Changelog

## Unreleased

### Added

- Add a Pester-based quality gate with structured test results, core-code coverage enforcement, exact test dependency versions, actionable static analysis, and a generated package inventory.
- Add integrity-checked Windows and Linux packages for kind, k3d, and kubectl to support Toolchain-managed local Kubernetes clusters.
- Add checksum-verified Windows and Linux K9s packages for the `toolchain k9s` cluster UI command.
- Add a Windows Docker Desktop bootstrap package that discovers Docker's current release, downloads it directly from Docker, verifies its SHA-256 and Authenticode publisher, and keeps license acceptance explicit.
- Add Windows Podman CLI and Podman Machine helpers rebuilt from checksum-verified source modules with patched Go and `x/crypto`, with no automatic host or VM configuration.
- Add signed package-health catalog publication, weekly durable-tag rescans, and clean consumer/cluster certification workflows.
- Add canonical signed multi-platform OCI indexes while retaining platform-specific compatibility aliases.
- Add checksum-verified Windows and Linux packages for Cosign, ORAS, Syft, Trivy, Crane, Talosctl, Flux, Argo CD, Stern, and Kubeseal.
- Add deterministic offline release rehearsals, catalog performance budgets, and automated container-base digest refresh pull requests.
- Add automated immutable Toolchain consumer promotion with one coherent manifest/workflow pin and real Windows PowerShell 5.1, Windows PowerShell 7, and Linux PowerShell 7 package-consumer tests.
- Raise the production-code coverage gate to 85% with lifecycle, integrity, Docker publication, release pagination, cache, subprocess, model-install, and isolated-runtime regression tests.
- Add daily and post-rescan signed package-health monitoring with retained reports and automatically managed GitHub alert issues.
- Add signature-, SBOM-, and provenance-verified package alias rollback plus three-platform Toolchain consumer rollback.

### Security

- Pin Windows and layered Linux container bases by digest, reject malformed semantic versions, and isolate descriptor reads so global package state cannot leak between inventory operations.
- Verify downloaded package inputs and cache hits before execution.
- Rebuild K9s 0.51.0 for Windows and Linux from checksum-database-verified Go modules with a patched Go toolchain and dependency graph.
- Rebuild kubectl for Windows and Linux from checksum-verified Go modules with patched Go, `x/net`, `x/sys`, and `x/text` dependencies.
- Rebuild Cue and Helm from checksum-verified Go modules with fixed `x/text` and `oras-go` dependencies.
- Restore Node 22 and Node 24 to the normal fail-closed scan gate with checksum-verified npm 12.0.2 and fixed dependency overlays, without vulnerability exceptions.
- Rebuild Docker CLI and daemon 29.7.2 from their immutable upstream commits with Go 1.26.6, preserving Windows service resources while removing vulnerable Go 1.26.5 binaries, and verify both source archives with pinned SHA-256 values.
- Rebuild Dependabot CLI 1.92.0 without its Go module cache, reject the daemon authorization package at source-graph verification time, and document its daemon-only Moby advisory status with OpenVEX.
- Verify NASM and Zstandard with version-pinned SHA-256 values independently reviewed through immutable Microsoft WinGet manifest commits.
- Exclude caches and temporary build content from published images.
- Fail closed when signing or compatibility contracts are required.
- Reduce CI permissions and secret exposure to protected release jobs.
- Confine legacy descriptor state to disposable runspaces and remove the remaining process-global asset hash cache.

### Changed

- Treat native build-tool stderr as diagnostic output while using the process exit code as the fail-closed result, preventing successful cold-cache Go builds from being rejected by isolated package runspaces.
- Preserve `${.}` exactly when a custom local package root ends in `pkg`, instead of re-expanding the already resolved path through the legacy `\pkg` compatibility rule.
- Make platform-alias publication compatible with older Docker Buildx clients and safely repair missing aliases from reverified immutable package evidence.
- Use the platform-specific `kubectl-linux` package in Linux compatibility and post-publication certification, and reject runner-provided binaries that resolve outside Toolchain's digest-addressed content store.
- Make `toolchain-consumer.json` the sole Toolchain pin, prevent promotion bots from modifying workflow files, validate promotions inside the initiating workflow, and merge them automatically only after all consumer gates pass.
- Select the newest durable image during scheduled vulnerability rescans and require explicit 1-90 day retention on every workflow artifact.
- Clean abandoned Docker Hub staging tags and orphaned Cosign attachments with dry-run previews, a publication safety delay, race-free release concurrency, and pagination resilient to Docker Hub's delayed tag-count refresh.
- Remove version tags selected by fully or partially quarantined package descriptors, along with Cosign attachments that no remaining durable tag references, using a fail-closed dry-run-capable maintenance job.
- Build ordinary Linux tool packages from `scratch` so extracted Toolchain packages contain only their intended payload instead of unrelated base-image files, vulnerabilities, hard links, and whiteouts, while contract tests inspect their stopped filesystems with a never-executed placeholder command.
- Disable large-model publication jobs and replace hanging live transparency-log lookups with offline verification of Cosign's signed Rekor bundles, inherited subprocess output, and bounded internal, process, and GitHub step deadlines.
- Make manual package publishing targeted by default, require explicit full-inventory opt-in, preserve shared runner capacity with bounded release parallelism, and bound Cosign verification with timeouts and retries.
- Route push publication jobs from changed package and asset paths, use bounded representatives for shared infrastructure, and reserve automatic complete inventory sweeps for scheduled runs.
- Normalize package `path` definitions to the case-sensitive Linux `PATH` variable during local execution.
- Prefer GitHub's bounded latest-release endpoint, fall back across releases that contain the requested asset, and avoid oversized release-history responses.
- Ignore nonmatching upstream and registry tags so newer Node major lines and package-name prefix collisions cannot break version discovery.
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
- Split cache, definition, local-execution, and descriptor-runtime responsibilities out of the shared utility layer.
- Write workflow matrices relative to the active repository and fail cleanly when Docker signing cannot resolve an immutable digest.
