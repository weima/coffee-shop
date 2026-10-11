# Rachel

![Rachel mascot](../../assets/characters/rachel.svg)

Rachel is a local terminal assistant in development for people editing Odin code. Run her against a project directory; she watches saved `.odin` files and gives fast, visible feedback without taking control of production source.

## Intended loop

```sh
cd tools/rachel
just run /path/to/odin-project
```

Rachel currently polls for Odin file updates every 250 ms, coalesces changes for a 350 ms quiet period, and runs the watched project's `just check` and `just test` recipes. If no root justfile exists, she creates a starter with those recipes and package arguments. Test failures and allocator-leak diagnostics become `[ERROR]` terminal feedback. On a changed production file, Rachel creates its missing companion test file without overwriting an existing file. She warns about newly added procedures without intent comments and production-looking code in newly created `*_test.odin` files. When `RACHEL_TEST_GENERATOR` is configured, she can generate and validate tests for documented procedures without a matching test.

```sh
RACHEL_TEST_GENERATOR=/path/to/local-generator just run /path/to/odin-project
```

The project justfile is left untouched when present. Rachel creates the starter only when none exists; see [justfile integration](architecture.md#justfile-integration).

The generator is a trusted local executable. It reads one versioned JSON request from stdin and returns test source as JSON on stdout; see [the protocol](architecture.md#local-generator-protocol).

## Test-file convention

- Production source uses names such as `memory_usage.odin`.
- Test source uses the reserved suffix `*_test.odin` and contains Odin tests.
- Rachel reserves `*_test.odin` for test source. Changes to these files are compile-checked and tested; automatic test generation will never create a companion such as `memory_usage_test_test.odin`.
- If a newly created `*_test.odin` file appears to contain production code rather than tests, Rachel gives a visible naming warning and suggests a production filename, for example `memory_usage.odin`.

Generated tests are written directly to the working tree. Rachel rechecks the source and test file before writing and leaves the file untouched if a concurrent edit is detected. Generated test code runs with the developer's normal permissions; the configured generator and generated code are not sandboxed. Rachel does not rewrite production source, run formatters over unrelated files, commit changes, or push branches.

## Status

The watcher, compile/test feedback loop, missing-intent warnings, test-filename conflict warnings, companion-test creation, and provider-neutral test-generation adapter are implemented. The adapter can use any trusted local command; Rachel does not own model credentials or depend on Pi. Further test-generation quality tuning and Linux verification remain open.

`cd tools/rachel && just test` passes 14 tests without allocator-leak warnings; `just build` succeeds. Linux verification remains outstanding.

- [Architecture and diagrams](architecture.md)
- [Implementation plan](PLAN.md)
- [Roadmap](ROADMAP.md)
- [Mascot](../../assets/characters/rachel.svg)
