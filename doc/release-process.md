# Release process

Toolchains releases use immutable artifact promotion:

1. resolve and verify upstream source versions and checksums;
2. stage package content in an isolated package root;
3. build the OCI image once and record its digest;
4. scan that exact image and generate its SBOM;
5. run Toolchain compatibility contracts against the same digest;
6. publish or promote that digest without rebuilding;
7. sign the digest and attach provenance;
8. verify the registry digest, signature, SBOM, and provenance after publication;
9. remove the successful run's temporary `staging-*` tag through Docker Hub's tag-specific API;
10. after the complete release matrix succeeds (or a validated no-op run), publish a complete generational model catalog from explicit package tiers.

Failure or unavailability of a required scanner, signer, contract, or provenance step blocks promotion. Release jobs run only from protected refs and environments. OIDC and registry credentials are scoped to the signing and publishing jobs.

Before a release matrix begins, Windows and Linux scanner-smoke jobs verify that
the pinned Syft and Trivy versions can be installed and executed. Each package
then captures scanner outcomes independently before enforcing the evidence gate:
a missing SARIF/SPDX file is reported as scanner infrastructure failure, while a
non-empty SARIF report is reported as a vulnerability finding. Evidence upload
is best-effort after a primary failure so a missing secondary artifact does not
hide the original cause. The final `package-health.json` artifact provides the
result and job URL for every selected package.

Manual workflow runs are package-targeted by default. Supply a package base name
such as `podman` or a repository-relative script path such as
`src/pkgs/podman.ps1`. A complete manual sweep requires explicitly enabling
`full_inventory`. Release matrices run at most eight package jobs concurrently,
and each Cosign verification command validates the signed Rekor inclusion bundle
offline, including the Fulcio certificate, claims, issuer, and workflow identity.
Cosign inherits the runner's output handles to avoid Windows redirected-stream
deadlocks. Bounded retries and internal, external, and job-level timeouts prevent
registry latency or a stuck child process from occupying a runner indefinitely.

Packages marked `VerifiedDownloads = $false` or `PublishEligible = $false` are quarantined before build and publication. Their reason is emitted in CI so maintainers can add publisher verification or wait for an upstream security fix; quarantine never converts an unverified or vulnerable input into an approved release artifact. Scheduled Docker Hub maintenance also removes version tags selected by quarantined descriptors. A partially quarantined package family must provide an anchored `Matcher` so cleanup fails closed instead of deleting supported family versions. Cosign attachments are removed only when no remaining durable tag references their subject digest.

Ordinary Linux package images use an empty `scratch` base because Toolchain
extracts their OCI layers directly and never executes them as containers. This
keeps package contents limited to the intended tool payload and avoids inheriting
unrelated operating-system files, vulnerabilities, hard links, or whiteouts.
Model-specific images may use a runtime base when their package contract requires it.
Exact-image contract testing supplies a never-executed placeholder command only
when creating the stopped inspection container; the artifact itself remains
commandless and is never started.

The unique `staging-*` tag makes a candidate addressable by digest for signing
and verification without exposing its immutable version tag early. It is
deleted only after the final version tag is proven to reference that signed
digest. A scheduled cleanup removes old staging tags left by failed or canceled
runs and Cosign `.sig`/`.att` attachments whose subject digest has no durable
non-staging tag. A safety delay and shared publication concurrency protect
in-flight releases. Manual cleanup previews changes by default. Cleanup uses
Docker Hub's tag endpoint and never deletes registry manifests or attachments
whose digest is still referenced by a final tag.

For rollback, move a mutable convenience tag only after selecting a previously verified immutable digest. Never overwrite a version tag.

Model category markers are untrusted discovery metadata, not package versions, authorization, or integrity evidence. An unprivileged job validates package descriptors and exports only the tier-derived model package names. A fresh, main-only publisher job downloads that plan, re-fetches registry tags through Docker Hub's documented namespace API, and publishes `tlc-kind-model-v1-<generation>-<count>--<package>` tags. An empty catalog uses the single `tlc-kind-model-v1-<generation>-0--empty` sentinel.

The publisher no-ops only when the highest observed generation is complete and matches the desired package set. Otherwise it advances beyond every observed generation, including any abandoned partial or conflicting generation, so delayed propagation cannot later supersede current intent. It uses one inspected existing manifest digest as non-authoritative transport for all tags, verifies each marker by its expected digest, and waits until Docker Hub reports the full generation. Older generations remain in place and no tag or manifest deletion is performed. Repository-wide job concurrency prevents two workflow runs from publishing shared catalog state simultaneously. Consumers must continue to verify package digests, signatures, and provenance through the normal pull path.
