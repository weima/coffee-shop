# Station tab lifecycle

A tab is an **allocated resource**, not a side effect of dispatch. Coffee Shop allocates
it for a Shot and **returns it to a pool** when the Shot no longer needs it, exactly as
allocated memory is freed rather than abandoned. This document specifies that lifetime,
the states a tab moves through, and the invariants that keep a wrong reclaim from
destroying work.

## The problem it solves

- **The host creates one Herdr tab per dispatch and never removes it.** Measured today:
  21 stale panes in one workspace, enough that the developer could feel the rendering
  drag. Nothing in the flow owned their lifetime.
- **Lifetime cannot be inferred from outside.** A cleanup script sees only the process
  list, so it must guess: match `--brew <request_id>` against a pane's directory, treat a
  `.git/wt/trash/` path as retired, and hope. Mine guessed wrong and closed a pane inside
  the developer's own workspace.
- **The dispatcher already knows.** It allocated the pane, it holds the session table
  (request → pane), it receives every Station report, and it can run a command in an
  existing pane. Allocation semantics belong to the allocator.

## The model

Tabs form a **bounded pool of worker slots**, borrowed from thread-pool practice:

| Thread pool | Tab pool |
|---|---|
| worker thread | Herdr pane (a tab in the repository's workspace) |
| task | one Shot's Station command |
| create a worker / reuse a free one | create a tab / **run the next Station in a freed tab** |
| pool size limit | the concurrency limit (today 5) |
| a worker returns to the pool when the task ends | a tab returns when the Station is done |
| the pool is destroyed when the executor shuts down | tabs are closed when the host exits |

Reuse is the point. Closing and recreating a tab per dispatch is the equivalent of
`malloc`/`free` on every allocation: it works, and it pays the creation cost every time,
while leaving every abandoned tab visible on screen.

## States

| State | Meaning |
|---|---|
| **FREE** | In the pool, no Station, cleared, ready to be reused |
| **ALLOCATED** | A Station command has been launched in it and is running |
| **WAITING_FOR_HUMAN** | The Station reported `needs_input`; a question is displayed and unanswered |
| **RECLAIMABLE** | The Station reached a terminal state, or its process is gone |

## Transitions

1. **Dispatch** acquires a tab: take a FREE one; if none is FREE and the pool is below its
   limit, create one; otherwise the dispatch waits for a tab — the pool limit *is* the
   concurrency limit, so queueing follows from the pool rather than from a separate rule.
2. Station launched → **ALLOCATED**.
3. **`needs_input` → WAITING_FOR_HUMAN, and the tab is pinned.** A human may be about to
   type into that pane; reclaiming it would hide the question and destroy the only path to
   the answer. The pin is released by an answer (a line typed in the pane, which the
   Station already forwards as a reply) or by an explicit cancel — **never by a timeout**.
4. Any terminal report — `pulled`, `taste_failed`, `incomplete`, `session_failed` →
   **RECLAIMABLE**.
5. **Process gone with no terminal report** (a crash) → **RECLAIMABLE**, with the failure
   recorded. Silence must not become success; this is the same rule state already follows.
6. RECLAIMABLE → clear the pane, mark **FREE**. The report is already durable under
   `~/.coffee-shop/host/reports/`, so clearing the pane loses no evidence the flow relies
   on — see the dependency below.
7. **Host exit → close every tab it owns.** A pool that outlives its allocator is a leak,
   and it is exactly the accumulation being fixed.

## Reuse mechanics

- Reuse means **running the next Station command in the existing pane**
  (`herdr pane run <pane_id> <command>`), not creating a tab.
- **Clear before reuse, and re-assert the terminal state.** The previous occupant may have
  died mid-draw, so reuse must reset the display *and* re-assert what a table would take
  for granted: auto-wrap on, cursor visible, attributes reset. The leftover-row bug was the
  animation's version of failing to clear; a reused tab is where that class of bug would
  come back, because a stale frame survives into the next task's output.
- **Tag every report with its request id** (already true) so a late report from a previous
  occupant is dropped rather than attributed to the new task. That is the pool's
  generation counter.
- Keep at least one pane in the pool's workspace while the host lives, or the workspace
  itself disappears and the pool loses its socket.

## Ownership boundary

The pool owns **only panes the host launched**, in the workspace the host created for the
repository. It never inspects, reuses or closes any other pane. This is not politeness: it
is the boundary an external heuristic crossed today, and the reason lifetime moves inside
the host.

## Invariants

1. A tab is reclaimed **only** from RECLAIMABLE — never from ALLOCATED or
   WAITING_FOR_HUMAN.
2. The pool never exceeds its limit.
3. No pane outside the host's own workspace is ever a candidate for reuse or closure.
4. The pool is emptied when the host exits.
5. A tab is cleared, and its terminal state re-asserted, before reuse.

## Dependency to settle first

**Reclaiming a tab assumes the report channel is durable, and today it is not.** When the
host died mid-session earlier, four Stations kept working and committing while their
terminal reports were never relayed — two of those completions were found only by
inspecting the branches by hand. Panes were the accidental backup for that. So tab reuse
makes the report gap load-bearing: either the host must write each report durably before
relaying it (or recover unrelayed ones on restart), or a reclaimed tab is no longer a place
a lost report can be recovered from.

## Recovery after a crash

A host that dies without exiting cleanly leaves its tabs behind, so a recovery path is
still needed. It should be **exact rather than heuristic**: the host already persists the
workspace it created, so it should also persist the panes it owns, and recovery closes
precisely those — not "anything whose directory looks like a Station". That is what makes
the external cleanup safe, instead of the guessing that closed a pane in the developer's
own workspace.

## Open questions

1. **Pool size.** The concurrency limit (5), or fewer? Tabs are display slots as well as
   workers, and a developer reads them, so five tabs of scrolling output may be worse than
   three.
2. **Host exit: close or keep?** Closing is honest and leak-free; keeping the pool makes the
   next host start faster and reuses the developer's existing layout, at the cost of
   orphaned tabs whenever a host dies badly.
3. **Cleared on completion, or kept for reading?** Today I read finished panes when a report
   was missing. If reports become durable, clearing is safe; if not, keeping the last
   occupant's output is the safety net — at the cost of the accumulation this design exists
   to remove.
4. **Do WAITING_FOR_HUMAN tabs count against the limit?** A pinned tab is not working, but
   its pane is occupied; counting it can starve dispatch, not counting it can overrun the
   screen.
