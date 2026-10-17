# Wrappers around the documented Odin commands; the Filter discovers `test`.

build:
    odin build src -out:coffee-shop

check:
    odin check src

# ODIN_TEST_FAIL_ON_BAD_MEMORY makes the runner count leaks and bad frees as test
# failures, so a memory error can no longer ride along with "All tests were successful."
# The test binary and its dSYM bundle are written to a private temporary directory so
# nothing lands in the repository for `git add -A` to stage.
test:
    sh tests/test-suite-lock.sh
    sh scripts/test-suite.sh

# Five-Station gates 5.8-5.10: see scripts/five-station-gates.md.
gates-selftest:
    python3 scripts/five-station-gates.py selftest

gates-request repo out:
    python3 scripts/five-station-gates.py request --repo {{repo}} --out {{out}}

gates-report request events state trace out:
    python3 scripts/five-station-gates.py report --request {{request}} --events {{events}} --state-dir {{state}} --trace {{trace}} --out {{out}}
