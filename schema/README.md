# Vendored Toolchain package specification

This directory is a vendored snapshot of the canonical contract in the Toolchain repository. `PACKAGE_SPEC_VERSION`, the JSON Schema, manifest, and every fixture must remain byte-for-byte equivalent after newline normalization.

Run `scripts/test-package-spec.ps1` to validate producer behavior and detect drift when a sibling Toolchain checkout is available. Use `scripts/update-package-spec.ps1 -SourceRoot <Toolchain/schema>` to perform an intentional upgrade, then review the contract changes and package compatibility before merging.
