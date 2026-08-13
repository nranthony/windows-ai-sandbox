---
name: clickup-report
description: Report a work/ item's progress back to its linked ClickUp task — a status transition and/or a short comment on a hurdle or change of direction. Dry-run first, always. Use when starting, blocking on, or finishing tracked work. Requires a repo-root .myclickup.toml with a pinned workspace; stops immediately without one.
argument-hint: <work item path> [status | "comment text"]
disable-model-invocation: true
---

# Report a work item back to ClickUp

Report on: $ARGUMENTS

**This is the only skill that writes to ClickUp.** Its whole surface is a status change
and a comment.

The convention behind this is recorded as **ADR-0008** in the conventions repo
(`docs/adr/0008-clickup-work-sync.md`). Deliberately not a link: this file ships inside a
plugin, and a relative path out of the payload resolves nowhere.

## What may cross, and what may not

May cross:

- a **status transition**, named by its role in `[statuses]` rather than by the Space's
  spelling — `agent_ready` → `agent_working` → `review` / `complete`, or `agent_working` →
  `human_active` when handing back to a human
- a **short comment** on a hurdle, a blocker hit, or a significant change of direction

**Must not cross:** plan or notes content, spec text, diffs, file paths, ADR bodies,
command output, or anything longer than a few sentences. A tracker's value is being
low-cognitive-load; pasting markdown into it destroys the one thing it is better at than
the repo. If the detail matters, it belongs in the work item — link the item, don't quote
it.

## Preflight — stop, don't improvise

1. **`myclickup` on PATH?** If not, stop — this is a human step. `myclickup` is a personal
   CLI distributed from the owner's `myclickup` repo; it is **not on PyPI**, so there is no
   install command to guess at. In the sandbox it is baked into the image, so its absence
   means the image needs updating; on any other machine, ask the human to clone the repo
   and install the wheel. Never fall back to raw HTTP against the ClickUp API.
2. **`myclickup --version` ≥ 0.3.0?** If lower, stop and ask for an upgrade. Older CLIs
   have no `set-status` and no derived `blocked_by`, so both the write below and the
   blocker gate would have to be improvised — and a tracker write is not the place.
3. **`.myclickup.toml` present, `workspace_id` non-empty?** If not, stop — same rule as
   `/clickup-pull`. Never guess an ID.
4. Resolve the target status through `[statuses]`, never by hard-coded name — including the
   terminal one, which is `statuses.complete`. If the role you need is absent from the
   table, say which key is missing and stop; do not substitute a name that looks right.
   **Compare case-insensitively** — ClickUp returns status names lower-cased
   (`"ready for agent"`) whatever the UI shows, so an exact match against
   `"Ready for Agent"` finds nothing. Send the `[statuses]` spelling on writes; read back
   case-insensitively. When you are *reading* whether something is finished — this task or
   a blocker — judge by the status **`type`** field (`done`/`closed`), never by name. To
   see what a list defines, `myclickup statuses --list "<path or id>" --live`.
5. Read the item's `ClickUp:` front-matter. No pointer means nothing to report — say so
   rather than guessing which task was meant.
6. **Re-read the task live** — `myclickup task <id> --json --live`, `--live` explicitly —
   before deciding anything. The front-matter is a snapshot; a human may have moved the
   task since, and the cache would hand you that same snapshot back.
7. **Blocker gate — only when transitioning *into* the `agent_working` status.** Take the
   task's derived `blocked_by` array (plus any `ClickUp-blocked-by` the item records) and
   read each of those tasks live too; a recorded status does not count. Judge each by its
   status `type`: `done`/`closed` is cleared, anything else is live. **A live blocker stops
   the transition** — do not write the status. Report which task blocks it and, if a
   comment was also asked for, offer to post that instead.

## Dry-run first — always

    myclickup --dry-run set-status <id> "<resolved name>"
    myclickup --dry-run comment <id> <text>

The transition goes through `set-status`, not `update --status`: it writes that one field
and checks the name against the statuses the task's list defines before sending. `--dry-run`
is accepted at the root or on the subcommand itself — same request either way.

Show the resolved request, then run the same command without `--dry-run` and answer the
permission prompt. This matters more here than usual: the prompt shows argv, not what it
resolves to, and the output lands in a surface a human reads visually.

## On completion

Completion is the `statuses.complete` role — resolve the name through `[statuses]` like any
other, and read completion state back by status `type` (`done`/`closed`), since the name a
Space uses for its terminal status is not knowable in advance. If `[statuses]` has no
`complete` key, stop and ask for it rather than sending a guess: a status that does not
exist in the task's home location is rejected outright.

Before reporting complete:

- confirm the work item's own exit rule is satisfied — anything durable distilled into an
  ADR or `docs/`, then archived
- check `ClickUp-blocks:` and **name the now-unblocked tasks** in your summary to the
  human, so they can be queued. Do not silently re-status them.

## After writing

Update the item's front-matter: `ClickUp-status` to the new value and
`Synced: <date> — pushed: <status>`. The push is not done until the local record says so.

## Never

- Batch a comment per subtask. A fan-out reports **once, on the parent**, listing the
  created item slugs.
- Move a task between Lists. The queue is a status; tasks stay where the human's mental
  model put them.
- Attempt to create a status. Custom statuses are per-Space and defined in the ClickUp UI
  by a human; `myclickup` has no command for it, and ClickUp rejects a status that does
  not exist in the task's home location.
- Delete anything. The CLI's whole write vocabulary is `create`, `update`, `set-status`,
  `claim`, `comment`, `tag`, `untag` — no delete, and `untag` removes a tag, nothing more.
