# Rachel Roadmap

| Milestone | Outcome | Status |
|---|---|---|
| 0. Design | Architecture, operating conventions, implementation plan, and diagrams prepared before code. | Drafted; generator backend remains open |
| 1. Live Odin checks | Foreground watcher runs debounced `odin check` and gives persistent, actionable diagnostics. | Planned |
| 2. Test-file health | Changes to `*_test.odin` run package tests and surface test failures and allocator leaks without recursive test generation. | Planned |
| 3. Contract guidance | New procedures receive advisory warnings when intent/contract comments are absent. | Planned |
| 4. Test generation | A provider-neutral local command adapter returns test source; Rachel writes it to the matching test file and validates it. | Planned; protocol and first adapter require confirmation |
| 5. Cross-platform release | Linux/macOS watcher behavior, output, and cleanup are verified. | Planned |

The roadmap tracks deliverable milestones. Task-level acceptance checks and sequencing live in [PLAN.md](PLAN.md); behavioral boundaries live in [architecture.md](architecture.md).
