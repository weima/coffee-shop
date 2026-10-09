# SQLite Binding Roadmap

## V1: Oreo persistence boundary

- Build a pinned official SQLite amalgamation into Oreo.
- Ship the minimal Odin API required by the session store.
- Prove real file-backed session metadata persistence through store end-to-end tests on Linux and macOS.

**Exit condition:** Oreo builds without a system SQLite installation, and its store can write, close, reopen, and query session metadata using the real bundled engine.

## Later, only when required

- Expand the exposed SQLite API only for a concrete Oreo feature.
- Add additional connection strategies only if concurrency measurements show the initial serialized store access is insufficient.
- Revisit source version and build options deliberately; record and test every SQLite upgrade.

No general-purpose ORM, FTS, or connection pool is planned for v1.
