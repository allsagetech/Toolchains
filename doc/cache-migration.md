# Build-cache migration

Download caches are build inputs, not package content. Set `TLC_CACHE_ROOT` to a persistent runner cache outside `TLC_PKG_ROOT`. The compatibility default may still locate an older cache beneath the package root, but generic Docker builds exclude `cache`, `_stage`, partial downloads, and temporary files. Package executables and archives are not excluded by extension because some packages intentionally distribute them; package authors must keep download-only inputs outside the package root.

To migrate a self-hosted runner:

1. stop active Toolchains jobs;
2. move the old `TLC_PKG_ROOT/cache` directory to the configured `TLC_CACHE_ROOT`;
3. verify ownership and restrict write access to the runner identity;
4. clear unverified or partially downloaded entries;
5. run package validation and one representative build before enabling publication.

Cache hits are revalidated against the expected digest. A cache entry without trustworthy digest metadata is treated as a miss.
