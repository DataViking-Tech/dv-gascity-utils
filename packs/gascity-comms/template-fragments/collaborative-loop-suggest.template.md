{{ define "collaborative-loop-suggest-mayor" }}
## Collaborative Loops With Peer Mayors

Cross-city threads between mayors heat up when reply turnaround
collapses to minutes. The full architecture and the structural
limitation that motivates this protocol live in
`docs/cross-city-comms.md` (Limitations) and the refinery
materialization writeup (`dgu-3u9` / `dgu-fze`). The protocol below
is the practical answer: you (mayor) detect the heat, surface a
single-line suggestion to the human, and once the human kicks
`/loop` off ONE time, you self-pace polling from there.

One-gesture-then-autonomous is the realistic ceiling: a true
zero-touch supervisor "wake into a new turn" needs upstream work in
gc itself. Until that lands, this fragment is how both mayors agree
on the same prompt at the same moment.

### Detect: when a collaborative thread is active

Treat a thread as **active** when ALL of these hold:

- at least 2 inbound mails from another mayor address
  (`origin-city != self-city`) on the same subject prefix within
  the last 30 min
- the most recent inbound is less than 5 min old
- no `/loop` is currently active for this thread

The shape is "they just replied, and they have replied AT LEAST
ONCE BEFORE recently" — a real back-and-forth, not a single ping.
A single inbound never trips the suggestion (one ping doesn't make
a thread).

Read the inbox via `gcx mail inbox` (or `gc mail inbox`) and the
origin via the `X-Gascity-Origin: <city>:<alias>` line that `gcx`
stamps at the top of cross-city bodies (or, when reading via `gcx
mail read`, the rewritten `From:` header). See
`docs/cross-city-comms.md` for the addressing details.

### Surface: the one-line suggestion

When the heuristic fires, surface ONE compact line to the human at
the next user turn. Do not mail. Do not nudge. This is in-band
guidance, not a notification:

> Cross-city thread with `<peer-city>` active (subject: `<S>`).
> Recommend a 5-minute `/loop` on this thread to stay synced.

Suggest at most once per active thread per session. Stop suggesting
once the human has started `/loop` for the thread, or the thread
has been quiet for 30+ min.

### Self-pace: once /loop is running

After the human kicks `/loop` off, you control cadence via
`ScheduleWakeup`. Pace by the age of the latest inbound on the
thread:

| Latest inbound age | Next wake delay |
|---|---|
| < 5 min | 60 s |
| 5 min – 30 min | 5 min |
| 30 min – 2 h | 15 min |
| > 2 h, or thread closed | exit `/loop` |

Each tick: re-check the inbox for new replies on the thread, run a
single short mayor turn (read, reason, reply or hold), then schedule
the next wake-up using the table. If both mayors have marked the
thread closed (subject prefix `[CLOSED]`, an explicit "closing this
thread" mail, or no inbound from either side for 2 h), exit `/loop`
on the next tick instead of scheduling another wake-up.

### Autonomous variant: enter the loop without the human gesture

When the human is AFK, the suggest-and-wait shape above stalls
waiting for `/loop`. The autonomous variant skips the human gesture:
you (mayor) call `ScheduleWakeup` directly with a self-contained
continuation prompt the moment the heuristic trips, and self-pace
from there using the same cadence table.

**Sender side (post-send wake).** Every successful
`gcx mail send <peer>:<role>` schedules ONE wake at 60 s with a
continuation prompt of the shape:

> Cross-city thread with `<peer>` active (subject: `<S>`). Check
> inbox for reply. If reply present: process and reply or hold,
> then re-schedule per age-bucket. If no reply: re-schedule per
> age-bucket. If thread closed: exit.

If you send multiple cross-city mails in one turn, collapse to a
single wake — last write wins. Don't stack waves of redundant wakes.

**Recipient side (inbound wake).** Trigger on EITHER:

- the existing heuristic (≥ 2 inbounds in 30 min, latest < 5 min,
  no active loop), OR
- a single inbound less than 60 s old from a peer city — autonomous
  variant only

The single-inbound branch is more eager than the human-facing
suggestion path because the cost of a false positive in autonomous
mode is one wasted wake (~60 s of cache-warm time). The cost of a
false negative — missing the start of an active back-and-forth where
the human takes time to compose — is meaningful. The bounded-runaway
guards (below) cover the "this turned out not to be a real thread"
case.

When either branch fires, schedule the first wake at 60 s with the
same continuation-prompt shape as the sender side, then self-pace
using the cadence table.

**Cadence.** Identical to the suggest-then-loop variant — pace by
the age of the latest inbound on the thread.

**Close conditions.** Identical (subject `[CLOSED]`, "closing this
thread" mail, 2 h quiet from both sides) PLUS one autonomous-only
guard:

- after 5 consecutive ticks with no further inbound, exit. Bounds
  runaway when the trigger turned out to be a one-off ping, without
  waiting the full 2 h timeout.

**Do not surface the suggestion line.** The autonomous variant skips
the human-facing message entirely. Don't print "Cross-city thread
with X active. Recommend a 5-min /loop." in this mode — you're
already in the loop.

**What this looks like to operators.** Mayor sessions appear "busy"
between human prompts in autonomous mode. ScheduleWakeup-driven
turns will fire even when the human isn't watching. That's the
intent — closing the autonomy gap that makes mayor sessions stall on
peer replies — but worth knowing so operators don't pattern-match it
as runaway. The 5-tick-no-progress guard plus the 2 h thread-quiet
exit bound the cost of any one trigger.

### Why this protocol exists

The gc supervisor cannot wake an interactive Claude Code session
into a brand-new turn — `mail-nudge` queues nudge text against an
existing turn, and the UserPromptSubmit hook on interactive mayor
sessions auto-marks unread mail as read on the human's NEXT prompt.
So an interactive mayor sitting idle between human prompts will not
autonomously notice peer replies even after `mail-nudge` fires (see
`docs/cross-city-comms.md` Limitations).

`/loop` plus `ScheduleWakeup` is the only path to autonomous polling
inside an interactive Claude Code session today. The suggest-then-
loop variant above asks for one human gesture per thread; the
autonomous variant skips even that. Pick whichever variant matches
the operator-supervision posture of this host — they share the same
detection logic, cadence table, and close conditions, so switching
between them is per-host opt-in, not per-thread.
{{ end }}
