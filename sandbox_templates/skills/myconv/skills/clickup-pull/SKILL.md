---
name: clickup-pull
description: Pull a ClickUp task (or its subtasks) into a work/NNNN-slug/ item, hydrating front-matter with identity, path and the dependency graph. Read-only against ClickUp — creates local files only. Use when activating a tracked task for agent work. Requires a repo-root .myclickup.toml with a pinned workspace; stops immediately without one.
argument-hint: <task-id or ClickUp URL> [--subtasks]
---

# Pull a ClickUp task into work/

Activate: $ARGUMENTS

**This skill never writes to ClickUp.** Every command it runs is a read. Setting the
task's status to `Agent Working` is `/clickup-report`'s job, so a pull can be reviewed
before anything becomes visible on the board.

**If these instructions are wrong, stale, or a bad fit for this repo:** file it with
`/myconv:report-skill-feedback` at the moment you deviate, before working around it.

The convention behind this — a tracker and `work/` are two projections of one item, synced
partially and asymmetrically — is recorded as **ADR-0008** in the conventions repo
(`docs/adr/0008-clickup-work-sync.md`). Deliberately not a link: this file ships inside a
plugin, and a relative path out of the payload resolves nowhere.

## Preflight — stop, don't improvise

1. **`myclickup` on PATH?** If not, stop — this is a human step. `myclickup` is a personal
   CLI distributed from the owner's `myclickup` repo; it is **not on PyPI**, so there is no
   install command to guess at. In the sandbox it is baked into the image, so its absence
   means the image needs updating; on any other machine, ask the human to clone the repo
   and install the wheel. Never fall back to raw HTTP against the ClickUp API.
2. **`myclickup --version` ≥ 0.3.0?** If lower, stop and ask for an upgrade. Older CLIs
   have no `subtasks` and no `set-status`, and their `task` output carries none of the
   derived fields used below (`blocked_by`, `blocks`, `path`) — which reads as a task with
   no relations rather than as an out-of-date tool.
3. **`.myclickup.toml` at the repo root?** If absent, this repo has no tracker link. Say
   so and stop — do not create one uninvited; it is an opt-in piece.
4. **`workspace_id` non-empty?** If empty, stop — the repo is declared-but-not-pinned, and
   empty does **not** fail: as of 0.3.0 it falls back to the token's *first* workspace
   with a warning, so the repo reads a real board that is simply the wrong one. **Do not
   guess an ID either** — a wrong-but-authorized one resolves silently, with no warning at
   all. Only a correct pin is safe, so ask for it.
5. Read `[statuses]` from that file. **Never hard-code a status name** — names vary per
   Space, which is the same reason completion is judged by the status `type`. A role the
   table does not define is unset, not "obvious": say which key is missing and stop rather
   than substituting a plausible name. `myclickup statuses --list "<path or id>" --live`
   prints what a list actually defines, each with its `type`.
   **Compare case-insensitively.** ClickUp returns status names lower-cased
   (`"ready for agent"`) regardless of how they were typed in the UI, so an exact match
   against a `[statuses]` value like `"Ready for Agent"` silently finds nothing.
6. `myclickup status` reports cache age and counts; `myclickup sync` refreshes it. Every
   read takes an explicit `--live` (bypass the cache) or `--cached` (fail rather than go
   live) — name one rather than relying on the default.
7. If `[work_sync].wip_limit` is set, count existing items whose `ClickUp-status` matches
   the `agent_working` name. At or over the limit, **warn and ask** before adding another.

## Pull

    myclickup task <id> --json --live

That emits the whole ClickUp object — `parent`, `linked_tasks`, `custom_fields` and the
raw `dependencies`, not just what the human formatter prints — plus the CLI's derived
`blocked_by`, `blocks` and `path`, which are what the front-matter below is built from.

With `--subtasks`, list the children directly (`myclickup subtasks <id> --json --live`) and
create **one item per child**, each carrying `ClickUp-parent`. Ask first if there are more
than a handful — a fan-out of twenty items is rarely what was wanted. **Then read each
child with `task`**: the entries `subtasks` returns are list-view summaries whose
`blocked_by`, `blocks` and `path` are `null`, and relations often sit on the children — a
parent can look unblocked while a child is genuinely blocked.

## Create the item

`work/NNNN-slug/proposal.md`, where `NNNN` is the next free number across active **and**
archived items (numbers are never reused) and the slug is derived from the task title, not
its ID.

Front-matter — required fields first, then only those ClickUp actually has a value for.
Absent fields are **omitted, never written empty**:

```markdown
- Status: Draft
- Synced: <YYYY-MM-DD> — pulled

- ClickUp: <id> — <url>
- ClickUp-status: <status name>
- ClickUp-path: <Space / Folder / List>
- ClickUp-parent: <id> — "<title>" (pulled as subtask N of M)
- ClickUp-blocked-by: <id> — "<title>" — not pulled, status: <name>
- ClickUp-blocks: <id> → work/NNNN-slug/
- ClickUp-related: <id> — "<title>" — not pulled
```

Then a `## From ClickUp` section quoting the task description **verbatim**, and the
repo's own proposal template headings below it.

Rules that make this worth having:

- **`ClickUp-path` is the payload's derived `path`** — never assembled by hand from `space`
  / `folder` / `list`, whose `folder` reads `{"name": "hidden"}` for any list sitting
  directly under a Space. If `path` is `null` the path is genuinely unresolvable: omit the
  field rather than inventing one.
- **Slug from the task title, cleaned.** Strip any leading work-item reference the title
  carries (`"0006 - testing"` → `testing`) so the local number stays the only number in the
  path. If what remains is too thin to identify the item later, say so and propose a better
  slug rather than creating `work/0007-testing/` and moving on.
- **`blocked-by` / `blocks` are the payload's `blocked_by` and `blocks` arrays**, already
  resolved for the task you asked about. Never re-derive direction from `dependencies`: one
  edge appears identically on both tasks and its `type` is not the direction. `related`
  comes from `linked_tasks`, a separate array.
- **Never write a bare ID.** Every relation carries either `→ work/NNNN-slug/` when that
  task has also been pulled, or its title plus last-seen status when it has not. A bare ID
  cannot be reasoned about, which is the definition of decorative.
- **Exclude `due`, `priority`, `tags`, assignee, description-as-metadata.** They change no
  agent behaviour and go stale silently. They are one `myclickup task <id> --live` away.

## Blocker gate — run it before calling the item ready

Once the front-matter exists, check every `ClickUp-blocked-by` entry: read each blocker with
`myclickup task <id> --json --live` — `--live` explicitly, since a cached status is exactly
the snapshot this gate exists to distrust — and judge it by its status **`type`** field, not
its name. `done` or `closed` means cleared; anything else (`open`, `custom`) is live.

If any blocker is live, **the item is blocked, not ready**: mark it so on its
`ClickUp-blocked-by` line (`— LIVE, blocks this item, status: <name>`), say which task
blocks it in your handoff, and do not present the item as available work — the next step is
clearing the blocker, not `/clickup-report`. A pull that quietly presents a blocked item as
ready is the failure this gate exists to prevent. If every blocker is cleared, say so — that
is also information the human wants.

## Re-pulling an existing item

Never clobber. Report a diff against the current front-matter and ask before applying it.
`notes.md`, `plan.md` and `spec.md` are owned by the repo and are never touched by a pull.

## Then

Tell the human what was created and what the next step is — normally
`/clickup-report <item>` to move the task to the `agent_working` status. Do not run it for
them. If the blocker gate found a live blocker, name it as the next step instead:
`/clickup-report` will refuse the transition anyway.
