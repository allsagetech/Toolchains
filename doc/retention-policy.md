<!-- Toolchains | SPDX-License-Identifier: MPL-2.0 -->
# Retention policy

Immutable package version tags, platform indexes, signatures, SPDX SBOM
attestations, SLSA provenance, and signed health catalogs are durable release
records. Workflows do not delete or overwrite them. Rollback moves only an
explicit `package-latest` or `package-stable` alias after verifying the selected
immutable digest.

GitHub Actions evidence uses explicit bounded retention on every upload:

- vulnerability scans, release evidence, package-health summaries, and monitor reports: 90 days;
- ordinary test logs: 14 days;
- candidate build archives: 30 days;
- intermediate plans and merged catalog inputs: 1–7 days.

Staging tags are temporary and are removed after successful publication or by
scheduled cleanup after the safety delay. Quarantined package tags may be
removed only through the quarantine cleanup's exact-tag, shared-digest-aware
rules. No maintenance workflow deletes an immutable healthy version tag.

Repository administrators should configure the repository-wide Actions
log/artifact setting to 90 days, the maximum for a public repository. Static
policy tests require every `upload-artifact` step to declare its narrower
retention explicitly and reject values above 90 days.
