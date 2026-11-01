# Wrappers around the documented Odin commands; the Filter discovers `test`.

# The Go host is embedded so one command carries both implementations. `odin check` and
# `odin test` do not pass the define, so they keep working without the Go artifact.
build: build-go
    odin build src -define:CSD_EMBEDDED=true -out:coffee-shop

build-go:
    cd go && go build -o ../src/csd.bin ./cmd/csd

# Run the built host with the Go implementation embedded. A recipe, not a bare binary, so
# the binary is always built from the current source first.
host-go:
    just build
    ./coffee-shop host --impl=go

check:
    odin check src
    cd go && go vet ./...

# ODIN_TEST_FAIL_ON_BAD_MEMORY makes the runner count leaks and bad frees as test
# failures, so a memory error can no longer ride along with "All tests were successful."
# The test binary and its dSYM bundle are written to a private temporary directory so
# nothing lands in the repository for `git add -A` to stage.
test:
    cd go && go test -race ./...
    cd go && go run ./suitelock ..

# Five-Station gates 5.8-5.10: see scripts/five-station-gates.md.
gates-selftest:
    odin run tools/gates -- selftest

gates-request repo out:
    odin run tools/gates -- request --repo {{repo}} --out {{out}}

gates-report request events state trace out:
    odin run tools/gates -- report --request {{request}} --events {{events}} --state-dir {{state}} --trace {{trace}} --out {{out}}

# Install the Pi prompt templates this repository ships, so they appear as
# slash commands. Pi reads user templates from ~/.pi/agent/prompts and reloads
# them on /reload.
install-prompts:
    mkdir -p ~/.pi/agent/prompts
    cp prompts/*.md ~/.pi/agent/prompts/
    @echo "installed: $(ls prompts/*.md | xargs -n1 basename | tr "\n" " ")"
