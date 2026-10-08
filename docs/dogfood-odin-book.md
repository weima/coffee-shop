# Dogfood: using Coffee Shop to extend "Odin in Practice"

The book is at `~/learn/odin` (repo `weima/odin-in-practice`). This page records the needs analysis, the plan, and the outcome of using Coffee Shop to do the work. Findings about Coffee Shop itself are in the last section.

## 1. What the book needs

Coffee Shop was built using the book as its Odin reference. Everything below cost real time while building it, and the book covers it little or not at all. "Coverage" counts the book's chapters and examples (`grep`, then read in context).

| Lesson from Coffee Shop | Where it bit | Book coverage |
| --- | --- | --- |
| `fmt.tprintf` returns temp-allocator memory: deleting it crashes; `fmt.aprintf` memory must be freed | A segfault on the second Herdr tab | Conceptual note in ch. 11 only; no trap shown |
| `fmt` treats `{` as a directive, so a JSON template mangles | Two test failures | None |
| A result name in a proc cannot be re-declared with `:=` (`Direct shadowing of the named return value`) | `run_herdr` | None |
| `:=` mixing existing and new names in one scope | Several tests | One unrelated hit |
| Default parameters must be constants (`now := time.now()`) | `next_brew_id` | Mentioned, no failing example |
| `for c, i in s` yields byte offsets, not a rune count | A review comment | Three passing mentions |
| `make_directory_all` can fail when two processes create the same directory | A real lost Worker report | None |
| Atomic replace (temp file, fsync, rename); append-only log plus snapshot | `state.odin` | One unrelated hit |
| Process identity: PID plus start time, zombies count as dead, `/proc/<pid>/stat` parsing | Cancel and recovery | Linux lab covers `/proc`, not identity |
| Killing a child leaves its children; process groups and `setsid` | Cancel | `process_kill` appears once in a capstone |
| Cancellation needs confirmed exit, else "unknown", never "completed" | Settle logic | None |
| Black-box CLI tests: build the binary, fake executables first on `PATH`, explicit environment, polling with deadlines | `e2e_test.odin` | None |
| `testing.expect_value`'s last parameter is a source location, not a message | Compile error | None |
| The book has no single verification command; CI repeats loops inline | Needed for the Filter | Absent |

Not in scope: new numbered chapters. `tools/check-book.py` asserts the chapter headings are exactly 1-31, so new material goes into existing chapters as unnumbered `###` subsections, plus runnable companions under `docs/examples/`.

## 2. Plan

Constraints discovered while planning:

- Examples must pass `odin check` (every `main.odin`) and the listed test suites. The compiler is the official `dev-2026-10` release the book already pins.
- `html/` and the offline ZIP are generated and tracked. Workers never rebuild them; one integration step does.
- `.venv` and `node_modules` are gitignored, so Stations lack them. Workers validate links with `mkdocs build --strict -d <scratch>`, using `.venv` through the Recipe's `share` list.
- Parallel Workers must not edit the same text. Each owns new files plus one distinct section of a chapter.

### Wave 1: independent additions (run in parallel, two at a time)

| Shot | Owns | Verification |
| --- | --- | --- |
| `durable-files` | `cli-linux.md` ch. 12 and 14 subsections; `docs/examples/12-durable-state/` | `odin check`, `odin test`, strict mkdocs |
| `supervision` | `cli-linux.md` ch. 15 subsection; `docs/examples/15-supervision/` | the same, tests run three times |
| `e2e-testing` | `cli-linux.md` ch. 21 subsection; `docs/examples/21-e2e-cli/` | the same, tests run three times |
| `ownership-traps` | `cli-linux.md` ch. 9 subsection; `docs/examples/09-ownership-traps/` | the same |
| `language-traps` | `odin-foundations.md` ch. 3-4 subsections; `docs/examples/04-language-traps/` | the same |
| `verify-entrypoint` | `justfile` | `just check`, `just test`, `just site` all pass |

### Wave 2: depends on wave 1

| Shot | Owns | Why it waits |
| --- | --- | --- |
| `workbook` | `workbook.md`: exercises and solutions, glossary terms, source trail | Needs the wave 1 text |
| `source-audit` | read-only report | Checks every API claim in the new text against the bundled Odin source |

### Integration (done by the Barista, once)

Apply each Shot's changes, update the example lists in `docs/examples/README.md`, the CI workflow and the justfile, rebuild `html/` and the offline ZIP, then run the book's own checks. Nothing is pushed.

Gates: every new example passes under `odin check` and `odin test` on `dev-2026-10`; `mkdocs build --strict` passes; `python tools/check-book.py` passes; no claim about compiler behaviour appears without a command that reproduces it.

## 3. Outcome and findings about Coffee Shop

_Filled in as the work proceeds._

Findings about Coffee Shop so far:

1. **A busy Worker looks dead.** `pi --print` prints only its final answer, so a running Worker's pane shows just the command line and `status` says only `running`. The first Wave 1 Shots were mistaken for stuck at about four minutes, while their Stations were gaining files and their Pi processes were active. Planned in [the v0.2.0 roadmap](../PLAN.md#roadmap-v020), item 1.
2. **Every Shot uses the same model and thinking level.** The book's Shots range from a one-file `justfile` to multi-section chapters with reproduced experiments. Planned in item 2.
3. **`share` worked as designed.** The book's gitignored `.venv` was linked into each Station, so Workers could run `mkdocs build --strict` into a scratch directory without installing anything and without dirtying the tracked `html/`.
4. **Nothing names the repository.** The Herdr workspace is `Coffee Shop <brew-id>` and the Git branches are `coffee-shop-<brew-id>-<shot-id>`, whichever repository the Brew is working on. Working on the Odin book, every label still says Coffee Shop. Planned as item 3 of the roadmap.
5. **Two Workers is a bottleneck.** The first book Brew has six independent Shots, so with a Scale of two it runs in three rounds, with most Shots waiting. Planned as item 4 of the roadmap (up to five).
6. **Prompts are awkward as inline JSON, and shared text gets pasted into every Shot.** The Wave 1 Recipe is about 35 KB of escaped strings, generated by a script, and the same ~3 KB block of rules is repeated in all six Shots. Planned as item 5 of the roadmap (`prompt_file`, `order_file`, and a shared preamble).
7. **A Shot can complete having done nothing.** `ownership-traps` finished with exit code 0, `completed`, and an empty Changes list. Its entire report was a plan ending "May I proceed with that design?": Pi in `--print` mode asked a question nobody could answer and exited. Coffee Shop records exit code 0 as `completed`, and the Oreo's decisions list did not mention it (a read-only task legitimately changes nothing, so "no changes" alone cannot be the signal). Mitigation used here: the shared Worker rules now say "you are not interactive, never ask", and the Barista reads every report. Planned as item 6 of the roadmap (a completion marker and an `incomplete` state).
8. **A Shot can complete with a progress note as its report.** `verify-entrypoint`'s whole report was "I fixed the `check` recipe and restarted the requested verification sequence." No results. The `justfile` turned out to be correct, but only because the Barista re-ran every recipe. Same root cause as finding 7: exit code 0 is all Coffee Shop requires. The shared rules now state that the last message must be a real report and that nothing may be reported while a check is unverified.
9. **Sharing one rules file by path works, with caveats.** The re-run of `ownership-traps` takes its shared rules from `docs/dogfood/odin-book-worker-rules.md` instead of 3 KB pasted into the prompt (the prompt shrank to the 2.2 KB that is unique to the Shot). Whether Workers reliably obey a "read this first" instruction is exactly what the re-run tests; see the result below.
