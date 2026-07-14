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
- Publish complete, generational model category markers from a names-only plan after successful or no-op main releases, with partial-propagation safety and no destructive tag cleanup.
