# Wrappers around the documented Odin commands; the Filter discovers `test`.

build:
    odin build src -out:coffee-shop

check:
    odin check src

# ODIN_TEST_FAIL_ON_BAD_MEMORY makes the runner count leaks and bad frees as test
# failures, so a memory error can no longer ride along with "All tests were successful."
test:
    TZ=UTC odin test src -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
