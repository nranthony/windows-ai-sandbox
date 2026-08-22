---
name: report-skill-feedback
description: File a report when a shared skill's instructions were wrong, stale, or a bad fit for the repo they ran in — or when the skill you needed didn't exist. One-way by design; file at the moment you deviate, before working around it.
argument-hint: <skill name, or missing:<topic>>
---

# Report skill feedback

A shared skill just told you something wrong, stale, or unfit for the repo in front of
you — or you went looking for a skill and there wasn't one. That moment is the most
valuable signal this toolchain gets, and it is destroyed the instant you quietly work
around it: your output will look fine, so nothing downstream ever notices. File first,
then work around (the decision record is ADR-0013,
`docs/adr/0013-skill-feedback-channel.md` in the conventions repo).

**The one-way rule:** a report must be actionable on arrival with no reply, and no
response is guaranteed. Unblock yourself locally regardless — never wait on this
channel, and never ask it questions.

## When to file

- **At the moment you deviate** from a skill's instructions — not at the end of the
  thread, when the details are gone.
- **Negative space counts:** "I needed a skill for X and there wasn't one" — file it
  as `missing:<topic>` with the envelope fields that apply.
- **Never patch the skill text itself.** Consumer copies — installed, seeded, or
  vendored — are read-only. Record the deviation in your repo, file it upstream, and
  leave the copy alone; a silent local edit turns drift invisible.

## Where the report goes

1. **Write it into your own repo first** — inside the work item you have open, or a
   `feedback/` folder if you have none. That tracked copy is the record.
2. **Copy it to the conventions repo's `inbox/`** as
   `<your-repo>-<skill>-<YYYY-MM-DD>-<slug>.md`. The inbox is a gitignored doorbell:
   the copy there gets promoted or deleted, never tracked.
3. **No path to that checkout?** (a container that cannot see it, a shell-less
   surface): keep the local file and state plainly that delivery is a human-ferried
   step. Do not improvise another transport.

## The envelope

Every field earns its place by removing a round trip. Fill them all; "unknown" is an
answer, silence is not.

```markdown
# Skill feedback: <skill> — <one-line summary>

- From: <repo> (<date>)
- Version: <the VERSION file beside the skill's SKILL.md, quoted verbatim —
  "no sidecar present" is itself version information>
- Install mode: plugin | user-scope | vendored container copy
- Invocation: <command and arguments as actually run>
- Artifact: skill | blueprint (reference/) | template | ADR
  <which text is actually wrong — not just which skill surfaced it>
- Broke at: <the step, quoted verbatim by its heading — or "missing:<topic>">
- Frequency: every run | once
- Symptom: <one slug from the list below, or none-fit:<your-word>>
- Verdict: generic | conditional on <repo-shape fact> | local to me
  <evidence, not opinion: which repo-shape fact the skill assumed — a justfile, a
  work/ tree, a pinned .myclickup.toml — and whether this repo has it>
- Risk class: mechanical | direction-setting
- Workaround applied locally: <what you actually did instead>

## Proposed edit
<quoted against the heading it belongs under — an edit, not a description of a
problem. Proposing it forces you to have read the skill; triage may still reword it.>
```

## Risk class — drawn by effect, not artifact

- **Mechanical**: the edit follows from what is already decided — a wrong path, a
  stale command, a step that cannot be followed as written, a clarification. This
  holds wherever the text lives, the blueprint included.
- **Direction-setting**: the edit would change what a guardrail, an ADR, or the
  blueprint *decides*. It routes to the ADR-first lane and is never merged from a
  report alone.

Your class is a claim, not a decision: triage may reclassify upward, never downward.
When unsure, say direction-setting — the cost of over-claiming is a slower lane, the
cost of under-claiming is a rule changed without its gate.

## Symptom slugs

One slug so repeats can be grouped — three reports of one friction are a signal, one
is an anecdote. Pick the closest: `wrong-path` · `stale-command` ·
`assumed-repo-shape` · `silent-skip` · `unclear-step` · `version-mismatch` ·
`missing-skill`. Nothing fits? Use `none-fit:<your-word>` — recurring none-fits are
how the list grows.

## The leak rule

Your report copies context out of a possibly-private repo into another one. Minimum
excerpt, no client or customer names, no identifying paths. Quote the skill freely —
it is the public text — and your own repo sparingly.

## What happens to your report

So expectations are set: a triage agent works the inbox in batch — collates, groups
repeats by slug, verifies each claim against the current text, and assesses
viability. Mechanical fixes are applied directly, with your report named in the
commit. Direction-setting proposals are presented to a human for discussion and
approval before anything is signed into an ADR. When a report becomes a change, the
`CHANGELOG.md` entry names it — that is the reply, and the only one.
