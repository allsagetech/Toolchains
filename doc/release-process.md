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

Failure or unavailability of a required scanner, signer, contract, or provenance step blocks promotion. Release jobs run only from protected refs and environments. OIDC and registry credentials are scoped to the signing and publishing jobs.

Packages marked `VerifiedDownloads = $false` are quarantined before build and publication. Their reason is emitted in CI so maintainers can add publisher verification or intentionally remove the package; quarantine never converts an unverified download into an approved release input.

For rollback, move a mutable convenience tag only after selecting a previously verified immutable digest. Never overwrite a version tag.
