# Bundled SQLite Amalgamation

- Upstream: [SQLite 3.54.0 amalgamation](https://www.sqlite.org/2026/sqlite-amalgamation-3540000.zip)
- Archive SHA3-256: `7b670a62fdfbd672b75fef004cb703c8a3e87d3a5cc7d675b4a08337004a2d93`
- `sqlite3.c` SHA3-256: `8efd453d08a7cfc4c79de5923153036cdc4dcaa254d4f1e617be6a2a98828f9e`
- Included files: `sqlite3.c`, `sqlite3.h`, and `sqlite3ext.h`. `shell.c` is not used.

SQLite is dedicated to the public domain. The amalgamation's source notice is preserved in `sqlite3.c`; see the [official copyright page](https://sqlite.org/copyright.html).

`cd oreo && just test` compiles the amalgamation with `SQLITE_THREADSAFE=1` and `SQLITE_OMIT_LOAD_EXTENSION`, then links the resulting object into the Odin tests. It does not link or load the system SQLite library.
