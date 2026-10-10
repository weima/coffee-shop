# Rachel

![Rachel mascot](../../assets/characters/rachel.svg)

Rachel is a planned local terminal assistant for developers editing Odin code. Run her against a project directory; she watches saved `.odin` files and gives fast, visible feedback without taking control of production source.

## Intended loop

```sh
rachel path/to/odin-project
```

After a short quiet-period debounce, Rachel checks the affected Odin package. She reports compile errors, runs package tests, treats allocator-leak warnings as failures, and warns when a procedure lacks an intent/contract comment. For a production module with no matching `*_test.odin`, she creates the companion test file; for a documented procedure with no matching test, she generates test code there and validates the result.

## Test-file convention

- Production source uses names such as `memory_usage.odin`.
- Test source uses the reserved suffix `*_test.odin` and contains Odin tests.
- Rachel never generates a companion test file for a `*_test.odin` file. She still syntax-checks and tests the package when that file changes; this prevents recursive names such as `memory_usage_test_test.odin`.
- If a newly created `*_test.odin` file appears to contain production code rather than tests, Rachel gives a visible naming warning and suggests a production filename, for example `memory_usage.odin`.

Generated tests are written directly to the working tree, as requested. Rachel does not rewrite production source, run formatters over unrelated files, commit changes, or push branches.

## Status

This directory currently contains design and planning documents only. The recommended design is a provider-neutral, local command adapter with a versioned JSON protocol; the first real adapter and its request schema remain implementation gates. Rachel will not own model credentials or depend on Pi.

- [Architecture and diagrams](architecture.md)
- [Implementation plan](PLAN.md)
- [Roadmap](ROADMAP.md)
- [Mascot](../../assets/characters/rachel.svg)
