# Wrappers around the documented Odin commands; the Filter discovers `test`.

build:
    odin build src -out:coffee-shop

check:
    odin check src

test:
    TZ=UTC odin test src
