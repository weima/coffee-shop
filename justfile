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
