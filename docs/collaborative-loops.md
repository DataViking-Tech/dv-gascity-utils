# Collaborative Loops Between Mayors

> **Status:** design + opt-in fragment. The fragment ships in `packs/gascity-comms/template-fragments/collaborative-loop-suggest.template.md` and is included into a host's mayor prompt template at the host's discretion (see "Opting in" below). No change to the upstream `gastown` mayor prompt is required.

## The problem

Two mayors on different cities are mid-conversation. Each reply lands
in the other city's inbox, `mail-nudge` ticks within 20 s and tries to
wake the recipient session, but the supervisor cannot mount an
interactive Claude Code session into a brand-new turn — it can only
queue nudge text against an existing turn. On an interactive mayor
session, the UserPromptSubmit hook auto-marks unread mail as read on
the human's *next* prompt. If the human is AFK, the mayor never
"sees" the peer's reply autonomously, and the thread stalls.

This is the structural limitation called out in the Limitations
section of `cross-city-comms.md` and revisited in the refinery
materialization writeup (`dgu-3u9` / `dgu-fze`): the supervisor lacks
a "wake into a new turn" primitive for interactive sessions. Until
that primitive lands, the only way to make an interactive mayor poll
autonomously is `/loop` + `ScheduleWakeup` from inside the session.

`/loop` requires exactly one human gesture to start. After that, the
mayor can self-pace its own ticks via `ScheduleWakeup`. So the gap
isn't really "zero-touch" — it's "make the one human gesture
*reliable and intentional*, on both sides, at the same moment."

That's what this protocol does:

1. Both mayors run the same heuristic to detect "collaborative
   thread is active."
2. Both mayors surface the same one-line suggestion to their
   respective humans at the next user turn.
3. Each human types `/loop` once.
4. Each mayor self-paces from there using `ScheduleWakeup` and an
   age-bucketed delay table, exiting when the thread cools down.

## The protocol

### Heuristic: "thread is active"

Trip the suggestion when ALL of:

- ≥ 2 inbound mails from another mayor address (`origin-city !=
  self-city`) on the same subject prefix within the last 30 min, AND
- most recent inbound is < 5 min old, AND
- no `/loop` is currently active for this thread.

The intent is "they just replied, and they have replied AT LEAST
ONCE BEFORE recently." A single isolated inbound is not a thread;
two inbounds within minutes of each other is. The 5-min recency gate
prevents stale threads from re-triggering on session restart.

Origin city comes from the `X-Gascity-Origin: <city>:<alias>` line
that `gcx` stamps at the top of cross-city bodies (rewritten as
`From:` when read via `gcx mail read`). See `cross-city-comms.md`
for addressing.

### Suggestion: one line, in-band

Surface to the human at the next user turn. **Do not mail.** **Do
not nudge.** This is in-band guidance, not a notification:

> Cross-city thread with `<peer-city>` active (subject: `<S>`).
> Recommend a 5-minute `/loop` on this thread to stay synced.

At most once per active thread per session. Stop suggesting once a
`/loop` is active for the thread, or the thread has been quiet for
30+ min.

### Self-pacing once `/loop` is active

The human types `/loop` once. After that the mayor controls cadence
via `ScheduleWakeup`. Pace by latest inbound age:

| Latest inbound age | Next wake delay |
|---|---|
| < 5 min | 60 s |
| 5 min – 30 min | 5 min |
| 30 min – 2 h | 15 min |
| > 2 h, OR thread closed | exit `/loop` |

Each tick: re-check the inbox for new replies on this subject, run
a single short mayor turn (read, reason, reply or hold), then
schedule the next wake-up using the table.

The `< 5 min → 60 s` bucket tracks active back-and-forth without
burning the prompt cache. The `5–30 min → 5 min` bucket assumes one
side is composing or thinking. The `30 min – 2 h → 15 min` bucket
keeps the loop alive across short interruptions. Beyond 2 h of
quiet, exit — the thread is not actively collaborative anymore.

### Closing a thread

A thread is closed when EITHER:

- a peer subject prefix changes to `[CLOSED]`, OR
- a peer mail explicitly says "closing this thread" (case-insensitive
  contains), OR
- no inbound has arrived from either side for 2 h.

When closed, the next `/loop` tick exits instead of scheduling
another wake-up.

## Opting in (per-host)

The fragment ships in this repo at:

```
packs/gascity-comms/template-fragments/collaborative-loop-suggest.template.md
```

It declares `{{ define "collaborative-loop-suggest-mayor" }}…{{ end }}`,
matching the gastown convention used by `propulsion-mayor`,
`capability-ledger-work`, etc. A mayor prompt template invokes it
with `{{ template "collaborative-loop-suggest-mayor" . }}`. The
upstream gastown mayor prompt template is **not** modified — opting
in is per host.

Three mechanisms, in order of cleanliness:

### 1. `inject_fragments_append` via `[[patches.agent]]` (cleanest)

The gc binary advertises `inject_fragments`,
`inject_fragments_append`, and `global_fragments` keys on
`[[patches.agent]]` (see `strings $(which gc) | grep
fragment`). When this works, the host adds a single patch in their
local `pack.toml` and the upstream gastown mayor prompt template can
expand the fragment without any prompt-template fork.

```toml
# In the host's local pack.toml (NOT in the upstream gastown pack)

[imports.gascity-comms]
  source = "/absolute/path/to/dv-gascity-utils/packs/gascity-comms"

[[patches.agent]]
  name = "mayor"
  inject_fragments_append = [
    "/absolute/path/to/dv-gascity-utils/packs/gascity-comms/template-fragments/collaborative-loop-suggest.template.md",
  ]
```

Use absolute paths until you have verified what relative-path
conventions your gc version supports (gc's documented templating
variables are `{{.ConfigDir}}`, `{{.RigRoot}}`, `{{.WorkDir}}`,
`{{.AgentBase}}`, `{{.Session}}`, `{{.Agent}}` — none of these
resolve to "the imported pack's root" today, so don't try to write
that). Run the verification step at the end of this doc to confirm
the fragment loaded before relying on this in production.

If option 1 works, the upstream mayor prompt template still needs
to *call* the fragment somewhere. Either edit your local fork of
the mayor template (option 2) to add a `{{ template
"collaborative-loop-suggest-mayor" . }}` line, or — if you're
willing to wait for upstream gastown to add an opt-in call site —
file a feature request there. Until upstream adds a hook, option 1
loads the define but nobody calls it; you need option 2 alongside
it for the full path.

### 2. `prompt_template` override via `[[patches.agent]]`

Copy the upstream mayor `prompt.template.md` into the host's local
pack, add a single `{{ template "collaborative-loop-suggest-mayor" . }}`
call at the desired position (a sensible spot is right after
`{{ template "propulsion-mayor" . }}` and before
`{{ template "capability-ledger-work" . }}`), then point a patch at
the override:

```toml
[[patches.agent]]
  name = "mayor"
  prompt_template = "agents/mayor/prompt.template.md"   # path inside the patching pack
  inject_fragments_append = [
    "/absolute/path/to/dv-gascity-utils/packs/gascity-comms/template-fragments/collaborative-loop-suggest.template.md",
  ]
```

The `prompt_template` field is documented in the binary's help text
("Use `--prompt-template` to copy prompt content from an existing
file into …" / "agent's `prompt_template` points at a file that
cannot be read"). Use this when you also want to customize other
parts of the mayor prompt locally — it's the most reliable path
because both the template and the fragment are pinned to absolute
paths you control.

### 3. Manual override (no patch)

If neither of the above works on your gc version, fork the mayor
prompt template into a local pack, paste the fragment body inline
where you want it (between `propulsion-mayor` and
`capability-ledger-work` is a sensible spot), and import that pack
instead of (or after) gastown's mayor.

This is heavier than option 1 — every upstream mayor prompt change
has to be re-merged — but it does not depend on any patch field
working as advertised.

## Worked example

Two cities, `yggdrasil` and `midgard`, with a mayor on each. They
have been mailing about a deploy plan; subject prefix on both sides
is `[deploy]`.

**T+0**. Yggdrasil mayor sends:

```
gcx mail send midgard:mayor -s "[deploy] proposed cutover Friday" -m "..."
```

Midgard's `mail-nudge` wakes the midgard mayor at the next user
turn. The midgard mayor reads the inbox: one inbound on `[deploy]`,
older than 5 min ago — heuristic does NOT fire (only 1 inbound).

**T+3 min**. Yggdrasil mayor follows up:

```
gcx mail send midgard:mayor -s "[deploy] proposed cutover Friday" -m "actually one more thing..."
```

Midgard mayor's next user turn now sees: 2 inbounds on `[deploy]`,
both within 30 min, latest under 5 min old, no `/loop` active.
Heuristic fires. Midgard mayor surfaces ONE line:

> Cross-city thread with `yggdrasil` active (subject: `[deploy]
> proposed cutover Friday`). Recommend a 5-minute `/loop` on this
> thread to stay synced.

Midgard's human types `/loop`. Midgard mayor processes the inbox,
drafts a reply, sends it via `gcx mail reply`, and calls
`ScheduleWakeup(60, ...)` because latest inbound age is < 5 min.

**T+5 min**. Yggdrasil mayor receives midgard's reply, fires its own
heuristic (now 2 inbounds from midgard on `[deploy]` in 30 min,
latest under 5 min). Yggdrasil mayor surfaces the same one-line
suggestion. Yggdrasil's human types `/loop`. Both mayors are now
self-paced.

**T+5 min … T+15 min**. Active back-and-forth. Each tick on each
side is `< 5 min` old → 60 s wake-up. Latency is essentially
"composing time + 60 s" rather than "composing time + (until next
human prompt)."

**T+30 min**. Conversation slows. Latest inbound on each side is
now ~10 min old → 5 min wake-up bucket.

**T+2 h 15 min**. No new mail in 30+ min from either side, but each
mayor is still on the 15-min bucket. On the next tick, latest inbound
age crosses the 2-h threshold. Both `/loop` instances exit.

The thread closes cleanly without either human having to
"remember to stop the loop" — the cadence collapses naturally as the
conversation cools.

## Autonomous variant (no human gesture)

The protocol above gates the loop on a human gesture (one `/loop`
per thread per side). When both humans are AFK, the suggestion line
surfaces and waits indefinitely. openclaw flagged this as a real
gap on 2026-05-01: cross-city collaboration stalls precisely when
neither human is watching, which is the case the protocol most
needs to cover.

The autonomous variant closes that gap. Same heuristic, same cadence
table, same close conditions; the *only* change is that the mayor
calls `ScheduleWakeup` directly with a self-contained continuation
prompt, instead of surfacing a suggestion and waiting for the human
to type `/loop`. Both variants ship in the same fragment — picking
between them is a per-host operator-supervision question, not a
per-thread decision.

### When the wake fires (sender + recipient triggers)

**Sender side.** Every successful `gcx mail send <peer>:<role>`
schedules ONE wake at 60 s with a continuation prompt:

> Cross-city thread with `<peer>` active (subject: `<S>`). Check
> inbox for reply. If reply present: process and reply or hold,
> then re-schedule per age-bucket. If no reply: re-schedule per
> age-bucket. If thread closed: exit.

Multiple cross-city sends in one mayor turn collapse to a single
wake — last write wins. Don't stack redundant wakes.

**Recipient side.** Trigger on EITHER:

- the existing heuristic — ≥ 2 inbounds from another mayor address
  on the same subject prefix in the last 30 min, latest under 5 min,
  no active loop — OR
- **a single inbound less than 60 s old from a peer city** (autonomous
  variant only).

The single-inbound branch is more eager than the human-facing
suggestion. Reasoning: the cost of a false positive in autonomous
mode is one wasted wake (~60 s of cache-warm time, no LLM cost
beyond the tick processing). The cost of a false negative — missing
the start of an active back-and-forth where the peer human takes
time to compose — is meaningful. The bounded-runaway guards below
cover the "turned out not to be a real thread" case.

The original ≥ 2-inbound heuristic was conservative because it
gated a *human-facing* suggestion (annoyance cost matters). The
autonomous variant gates only a self-scheduled wake, so the
conservatism budget shifts. Keep the existing heuristic for the
suggestion path; add the single-inbound branch as the
autonomous-only trigger.

### Cadence and close conditions

Both unchanged from the suggest-then-loop variant. Cadence table
(60 s / 5 min / 15 min / exit) paces by latest inbound age. Close
conditions (`[CLOSED]` subject prefix, "closing this thread" mail
contents, 2 h quiet from both sides) all carry over.

The autonomous variant adds one extra close condition:

- **5 consecutive ticks with no further inbound → exit.** Bounds
  runaway when a trigger turned out to be a one-off ping, without
  waiting the full 2 h timeout. At the 60 s bucket that's a 5-min
  cap on a false-positive trigger.

### Do not surface the suggestion line

In autonomous mode, skip the human-facing message entirely. Don't
print "Cross-city thread with X active. Recommend a 5-minute
`/loop`." — you're already in the loop. The suggestion line exists
for the *suggest-then-loop* variant only.

### What this looks like to operators

Mayor sessions appear "busy" between human prompts when the
autonomous variant is active. `ScheduleWakeup`-driven turns fire
even when the human isn't watching. That's the intent — closing the
autonomy gap that makes mayor sessions stall on peer replies — but
worth knowing so operators don't pattern-match it as runaway.

If you see a mayor turn fire without a human prompt and want to
confirm it's the autonomous variant rather than something unrelated:

```bash
# the most recent mayor turn started with one of these prompts
grep -A 1 'autonomous-loop-dynamic\|Cross-city thread with' \
  ~/<rig-root>/.gc/agents/mayor/sessions/*/transcript.jsonl 2>/dev/null \
  | tail -5
```

The 5-tick-no-progress guard plus the 2 h thread-quiet exit bound
the cost of any one trigger to at most ~5 min of false-positive
loop time. The 2 h cap covers the case where messages keep flowing
on a thread that's not actually generating useful collaboration.

### Worked example: autonomous flow

Reuse the earlier two-cities scenario, but neither human is at the
keyboard.

**T+0**. Yggdrasil mayor sends `[deploy] proposed cutover Friday`.
The `gcx mail send` post-send hook schedules
`ScheduleWakeup(60s, "Cross-city thread with midgard active …")`.

**T+1 min**. Yggdrasil's autonomous wake fires. The continuation
prompt instructs the mayor to check inbox. No reply yet (peer hasn't
turned). Schedule next wake per cadence table — latest inbound (the
one we sent) is < 5 min, so 60 s bucket.

**T+2 min**. Same thing — still no reply. Schedule another 60 s.

**T+3 min**. Midgard's mail-nudge fires (its own inbox grew by 1
when our send landed). Midgard mayor reads inbox: single inbound,
30 s old, peer city, autonomous variant tripped. Midgard schedules
its own wake at 60 s. Composes a reply, sends it.

**T+4 min**. Yggdrasil's autonomous wake fires. Reply present —
process it, draft response, send. Post-send schedules another 60 s
wake.

**T+4 min … T+30 min**. Active back-and-forth. Each side's wake
delay collapses to 60 s while the latest-inbound-age stays under
5 min. Latency is "composing time + 60 s," not "composing time +
(when the human next opens the terminal)."

**T+45 min**. Conversation slows. Latest inbound on each side is
now ~10 min old → 5 min wake-up bucket.

**T+2 h 15 min**. No new mail in 30+ min. Each mayor's autonomous
wake fires, latest inbound age crosses the 2 h threshold, both
loops exit.

The thread closes cleanly without either human ever typing `/loop`.

## Verification before relying on option 1

The fragment ships unconditionally; what's host-specific is the
opt-in mechanism. Before relying on option 1 in production, verify
on your gc version:

```bash
# 1. Add the patch and reload
gc reload

# 2. Render the mayor prompt and confirm the fragment expanded
gc agent prompt mayor 2>&1 | grep -A 2 "Collaborative Loops With Peer Mayors"
```

If the fragment text appears, option 1 works on your binary. If you
see `gc: inject_fragment %q: template not found` in the supervisor
log on agent startup, the path didn't resolve — fall back to option
2 (which uses an explicit `prompt_template` override) or option 3
(manual paste).

## References

- `docs/cross-city-comms.md` — full architecture; the **Limitations**
  section is the structural motivation for this protocol.
- `dgu-3u9` (refinery on-demand spawn investigation) and `dgu-fze`
  (refinery routing follow-up) — same upstream class of "supervisor
  cannot wake into a new turn" gap. The refinery side was solved by
  routing alignment + `gc session wake`; the mayor side cannot use
  `wake` because mayors are interactive sessions, not on-demand
  named slots.
- `docs/shared-rig-prefix.md` — the multi-city patterns this
  protocol assumes (cities sharing a prefix and a beads pool, mail
  flowing through the gateway).
- `packs/gascity-comms/template-fragments/collaborative-loop-suggest.template.md`
  — the fragment itself.

## Out of scope

- Changes to the upstream gastown mayor prompt template.
- Any change to `gcx`. Detection runs entirely against the inbox
  view that `gcx mail inbox` already exposes; the autonomous
  variant's post-send wake is scheduled by the mayor (not by `gcx`)
  in the same turn as the send, keeping `gcx` a thin transport.

## Variant selection (per host)

The fragment ships both variants. Selection is per host, not per
thread:

- **Suggest-then-loop** is the right default for hosts where a
  human is reliably watching the mayor session. The one-line
  suggestion is in-band guidance; one `/loop` gesture per thread.
- **Autonomous** is the right default for hosts where the human is
  expected to be AFK during cross-city collaboration. No suggestion
  line, mayor self-schedules. Bounded by the 5-tick-no-progress
  guard and the 2 h thread-quiet exit.

Hosts choose by adopting only the relevant heuristic in their
mayor's per-turn behavior — both detection rules live in the
fragment side-by-side, and the cadence/close logic is shared.
