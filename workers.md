# Coffee Shop Worker Rules

- Work only on the assigned Shot in its Station. Preserve Coffee Shop's CLI, lifecycle, and v0.1 compatibility boundaries.
- Do not implement Blend. Do not commit, push, open a PR, merge, publish, delete Stations/state, or change another repository.
- Read `standards.md`, the relevant architecture/plan sections, and existing source/tests before editing. Write focused failing tests first for behavior changes.
- Use the existing Odin toolchain and commands: `TZ=UTC just test`, `just check`, and `just build`. Do not replace or narrow them.
- Report changed files, tests and results, and anything incomplete. End with `CS-DONE` only when complete and verified, or `CS-BLOCKED: <reason>` when blocked.
