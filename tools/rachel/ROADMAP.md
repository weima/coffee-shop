# Rachel Roadmap

| Milestone | Outcome | Status |
|---|---|---|
| 0. Design | Architecture, operating conventions, implementation plan, and diagrams prepared before code. | Complete; external wrapper still needs verification |
| 1. Live Odin checks | Foreground watcher runs debounced `just check`/`just test` recipes and gives persistent, actionable diagnostics. | In progress; starter justfile and custom-recipe support being completed; cross-platform verification pending |
| 2. Test-file health | Changed production files get a companion `*_test.odin`; test files run package tests and surface failures/leaks without recursion. | In progress; companion creation, package tests, leak and naming warnings implemented |
| 3. Contract guidance | New procedures receive advisory warnings when intent/contract comments are absent. | Implemented |
| 4. Test generation | A provider-neutral local command adapter returns test source; Rachel writes it to the matching test file and validates it. | Implemented with fake generator; real wrapper and Linux verification pending |
| 5. Evaluate Rachel-guided development | Try one test-first Oreo vertical slice with Rachel in Herdr; run full E2E only after the slice is green and compare with batch-style AI work. | Candidate experiment; not the default until a human reviews the outcome |
| 6. Cross-platform release | Linux/macOS watcher behavior, output, and cleanup are verified. | Planned |

The roadmap tracks deliverable milestones. Task-level acceptance checks and sequencing live in [PLAN.md](PLAN.md); behavioral boundaries live in [architecture.md](architecture.md).
