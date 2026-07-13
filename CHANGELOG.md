# Changelog

## Unreleased

### Security

- Verify downloaded package inputs and cache hits before execution.
- Exclude caches and temporary build content from published images.
- Fail closed when signing or compatibility contracts are required.
- Reduce CI permissions and secret exposure to protected release jobs.

### Changed

- Separate package installation from build, publication, and signing.
- Promote the exact OCI artifact that passed scanning and Toolchain contracts.
- Pin the Toolchain build dependency to an immutable revision.
- Publish and validate a versioned package-definition contract corpus.
