# Release process

Toolchains releases use immutable artifact promotion:

1. resolve and verify upstream source versions and checksums;
2. stage package content in an isolated package root;
3. build the OCI image once and record its digest;
4. scan that exact image and generate its SBOM;
5. run Toolchain compatibility contracts against the same digest;
6. publish or promote that digest without rebuilding;
7. sign the digest and attach provenance;
8. verify the registry digest, signature, SBOM, and provenance after publication.
9. after the complete release matrix succeeds (or a validated no-op run), publish a complete generational model catalog from explicit package tiers.

Failure or unavailability of a required scanner, signer, contract, or provenance step blocks promotion. Release jobs run only from protected refs and environments. OIDC and registry credentials are scoped to the signing and publishing jobs.

Packages marked `VerifiedDownloads = $false` are quarantined before build and publication. Their reason is emitted in CI so maintainers can add publisher verification or intentionally remove the package; quarantine never converts an unverified download into an approved release input.

For rollback, move a mutable convenience tag only after selecting a previously verified immutable digest. Never overwrite a version tag.

Model category markers are untrusted discovery metadata, not package versions, authorization, or integrity evidence. An unprivileged job validates package descriptors and exports only the tier-derived model package names. A fresh, main-only publisher job downloads that plan, re-fetches registry tags through Docker Hub's documented namespace API, and publishes `tlc-kind-model-v1-<generation>-<count>--<package>` tags. An empty catalog uses the single `tlc-kind-model-v1-<generation>-0--empty` sentinel.

The publisher no-ops only when the highest observed generation is complete and matches the desired package set. Otherwise it advances beyond every observed generation, including any abandoned partial or conflicting generation, so delayed propagation cannot later supersede current intent. It uses one inspected existing manifest digest as non-authoritative transport for all tags, verifies each marker by its expected digest, and waits until Docker Hub reports the full generation. Older generations remain in place and no tag or manifest deletion is performed. Repository-wide job concurrency prevents two workflow runs from publishing shared catalog state simultaneously. Consumers must continue to verify package digests, signatures, and provenance through the normal pull path.
