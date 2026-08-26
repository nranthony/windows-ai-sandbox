---
name: clickup-pull
description: Pull a ClickUp task (or its subtasks) into a work/NNNN-slug/ item, hydrating front-matter with identity, path and the dependency graph, reading the comment thread, and recording what was left behind. Read-only against ClickUp — creates local files only. Follows the repo's own lifecycle and content rules rather than asserting a shape. Use when activating a tracked task for agent work. Requires a repo-root .myclickup.toml with a pinned workspace; stops immediately without one.
argument-hint: <task-id or ClickUp URL> [--subtasks]
---

# Pull a ClickUp task into work/

Activate: $ARGUMENTS

**This skill never writes to ClickUp.** Every command it runs is a read. Setting the
task's status to `Agent Working` is `/clickup-report`'s job, so a pull can be reviewed
before anything becomes visible on the board.

**It never states what your repo must contain, either** (**ADR-0015**,
`docs/adr/0015-skills-conform-to-the-repo-they-run-in.md`; the tracker-and-`work/` convention
underneath the whole skill is **ADR-0008**, `docs/adr/0008-clickup-work-sync.md` — both cited
by number, never linked, since a relative path out of a plugin payload resolves nowhere).
Where this repo publishes its own shape — `AGENTS.md`, its `work/README.md` lifecycle, its
ADRs, its existing items — that beats every default here; where it publishes nothing, take a
default and **name it as one**. A piece it does not keep is a *state*, not an error: proceed
on a stated basis, say what you assumed, and stop only where proceeding would be unsafe. A
search that finds nothing names the paths it checked rather than passing quietly. That holds
at every step below, not only the ones that spell it out.

**If these instructions are wrong, stale, or a bad fit for this repo:** file it with
`/myconv:report-skill-feedback` at the moment you deviate, before working around it.

## Preflight — stop, don't improvise

1. **`myclickup` on PATH?** If not, stop — a human step. It is a personal CLI from the
   owner's `myclickup` repo and **not on PyPI**, so there is no install command to guess at;
   in the sandbox its absence means the image needs rebuilding. Never fall back to raw HTTP.
2. **`myclickup --version` ≥ 0.3.0?** If lower, stop and ask for an upgrade: older CLIs have
   no `subtasks`, no `set-status`, and none of the derived `blocked_by` / `blocks` / `path`
   fields used below — which reads as a task with no relations, not as an out-of-date tool.
3. **`.myclickup.toml` at the repo root?** If absent, this repo has no tracker link. Say
   so and stop — do not create one uninvited; it is an opt-in piece.
4. **`workspace_id` non-empty?** If empty, stop: empty does **not** fail — as of 0.3.0 it falls
   back to the token's *first* workspace, so the repo reads a real board that is simply the wrong
   one. **Never guess an ID either**; a wrong-but-authorized one resolves silently. Ask for it.
5. **Status roles — read `[statuses]` if that file pins them.** **Never hard-code a status
   name**: names vary per Space, which is why completion is judged by the status `type`.
   `myclickup statuses --list "<path or id>" --live` prints what a list defines, each with its
   `type`. **Compare case-insensitively** — ClickUp lower-cases names however they were typed,
   so matching `"ready for agent"` against a pinned `"Ready for Agent"` finds nothing.

   **A missing table is a state, not an error**: a repo tracking work in `work/` rather than
   on a board has no reason to pin one. If a role you need is unpinned but the caller supplied
   the name, use it *explicitly* — validate it against the live list above, record on the
   item's `ClickUp-status` line and in your handoff that the mapping was **supplied by the
   caller, not pinned**, and stop with what the list does define if it matches nothing. With
   nothing supplied and nothing pinned, name the missing role and stop rather than guessing.

   **Read path only.** A name typed into a prompt that drives a *board write* is a different
   risk class: `/clickup-report` still requires a pinned role or an explicit confirmation of
   the exact name, and this convenience does not cross over.
6. Every read takes an explicit `--live` (bypass the cache) or `--cached` (fail rather than
   go live) — name one. `myclickup status` reports cache age; `myclickup sync` refreshes it.
7. If `[work_sync].wip_limit` is set, count existing items whose `ClickUp-status` matches the
   `agent_working` name; at or over the limit, **warn and ask** before adding another.

## Pull

If this repo restricts what may enter tracked files, read that rule before you pull — it
changes what the item you are about to write may contain (see `## Create the item`).

    myclickup task <id> --json --live
    myclickup comments <id> --json --live

`task` emits the whole ClickUp object — `parent`, `linked_tasks`, `custom_fields`, the raw
`dependencies` and `attachments`, not just what the human formatter prints — plus the
derived `blocked_by`, `blocks` and `path` the front-matter below is built from.

**Always read the comments**, even where the description looks complete: real scope routinely
lives in the thread, and a pull that never looked writes an empty item with no hint anything
was missed. Record the count and last-commented date **even when there are none** — "checked,
nothing there" must not read like "never looked"; quote any comment carrying scope the
description does not under `## From ClickUp`, attributed as a comment.

With `--subtasks`, list the children (`myclickup subtasks <id> --json --live`) and create
**one item per child**, each carrying `ClickUp-parent`; ask first if there are more than a
handful. **Then read each child with `task`** — `subtasks` entries are list-view summaries
whose `blocked_by`, `blocks` and `path` are `null`, and relations often sit on the children,
so a parent can look unblocked while a child is genuinely blocked.

## Create the item

`work/NNNN-slug/<file>`, where `NNNN` is the next free number across active **and** archived
items (numbers are never reused) and the slug derives from the task title, not its ID.

**Which filename is the repo's call.** Read its `work/README.md` — or whatever it calls its
lifecycle doc — and how its existing items are named; follow that. Where the lifecycle offers
both (this blueprint's opens an item as `proposal.md`, or for pre-decided work straight as
`spec.md`/`plan.md`), **default to `spec.md` for a pulled task and say so** — a task already on
a board is pre-decided almost by definition. With neither, name the default you took and why.

Front-matter sits **under the `#` title**, never as the file's first line — it is the part
meant to be machine-readable later, so placement is pinned rather than left to taste. Required
fields first, then only those ClickUp has a value for; absent fields **omitted, never empty**:

```markdown
# <title>
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

**Unless this repo restricts what may be committed.** A work item is a tracked file. If the
repo's `AGENTS.md`, an ADR, or a stated policy limits what may enter tracked files — party or
client names, matter or case numbers, sums, dates — that rule **wins over every instruction
in this section**, the same way a repo's own patterns beat a template in
`/myconv:apply-conventions`. Where it applies:

- derive the slug from the *kind* of work rather than the task title;
- replace the verbatim `## From ClickUp` quote with a restatement **labelled as
  de-identified**, saying in it that the verbatim text and the parties live in the tracker
  task;
- apply the same test to every field carrying a title or a path — `ClickUp-parent`,
  `ClickUp-blocked-by`, `ClickUp-blocks`, `ClickUp-related`, `ClickUp-path`. A title that
  cannot be written is replaced by a de-identified descriptor plus the last-seen status;
  **dropping to a bare ID is not the way out** — the never-write-a-bare-ID rule below still
  holds;
- keep `ClickUp:` id and URL exactly as they are. A pointer identifies nothing on its own,
  and without it the restatement cannot be checked against its source.

Say in your handoff that the item was de-identified and why — a silent de-identification
reads as a lossy pull. If you cannot tell whether a rule applies, ask before writing the
file. This is **ADR-0014** in the conventions repo
(`docs/adr/0014-repo-content-policy-overrides-skill-writes.md`); as with ADR-0008 above,
deliberately not a link.

Rules that make this worth having:

- **`ClickUp-path` is the payload's derived `path`**, never assembled from `space`/`folder`/
  `list` — `folder` reads `{"name": "hidden"}` under a Space. If `path` is `null`, omit it.
- **Slug from the task title, cleaned.** Strip any leading work-item reference (`"0006 -
  testing"` → `testing`) so the local number stays the only number in the path. If what
  remains cannot identify the item later, propose a better slug rather than moving on.
- **`blocked-by` / `blocks` are the payload's own `blocked_by` / `blocks` arrays**, already
  resolved for this task. Never re-derive direction from `dependencies` — one edge appears
  identically on both tasks and its `type` is not the direction. `related` is `linked_tasks`.
- **Never write a bare ID.** Every relation carries `→ work/NNNN-slug/` if that task was also
  pulled, or its title plus last-seen status if not — a bare ID cannot be reasoned about.
- **Exclude `due`, `priority`, `tags`, assignee, description-as-metadata.** They change no
  agent behaviour, go stale silently, and are one `myclickup task <id> --live` away.

## Attachments — record what exists, including what you left behind

A pull fetches no bytes (auto-download under a size cap is deferred); what it must not do is let
an attachment go unmentioned. Write a `## Attachments` **body section** — not front-matter, which
excludes anything that changes no agent behaviour and goes stale silently, and a size manifest is
exactly that shape. Per attachment: `title`, `mimetype`, `size`, `version`, the ClickUp `date`,
the pulled-date if pulled, the reason if not. If there are none, say so — in a tracked file,
silence and "checked, none" are not the same claim.

- **Never record the URL.** A signed URL puts an expiring credential in a tracked file, and is
  the wrong drift signal anyway: `version` and the ClickUp `date` both bump on replacement,
  which is drift detection with no hashing and no re-fetch.
- **Surface what the CLI skipped.** A download (`myclickup attachments <id> --download`) never
  overwrites — an existing file comes back in a `skipped` array beside `downloaded`
  (`myclickup` ADR-0010, rule 4). Report it rather than swallowing it; a skip is not a pass.

## Blocker gate — run it before calling the item ready

Once the front-matter exists, read every `ClickUp-blocked-by` entry with `myclickup task <id>
--json --live` (`--live` explicitly: a cached status is the snapshot this gate distrusts) and
judge it by status **`type`**, not name — `done`/`closed` is cleared, anything else is live.

If any blocker is live the item is **blocked, not ready**: mark its `ClickUp-blocked-by` line
(`— LIVE, blocks this item, status: <name>`), name the blocker in your handoff, and do not
present the item as available work — the next step is clearing it, not `/clickup-report`.
Quietly presenting a blocked item as ready is the failure this gate prevents; say so either way.

## Re-pulling an existing item

Never clobber. Report a diff against the current front-matter and ask before applying it.
`notes.md`, `plan.md` and `spec.md` are owned by the repo and are never touched by a pull —
`spec.md` included when an earlier pull is what created it. A section that was deliberately
de-identified is **not** drift: report that the source text changed and let the human decide,
and never restore verbatim wording an earlier pull left out on purpose.

## Then

Tell the human what was created and the next step — normally `/clickup-report <item>`, to move
the task to the `agent_working` status; do not run it for them. Say what you could **not** check
as well as what you did: a role taken from the caller rather than a pin, a lifecycle you could
not locate, comments or attachments that were absent. If a blocker is live, name clearing it as
the next step instead — `/clickup-report` will refuse the transition anyway.
