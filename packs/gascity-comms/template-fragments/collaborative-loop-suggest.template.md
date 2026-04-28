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

### Why this protocol exists

The gc supervisor cannot wake an interactive Claude Code session
into a brand-new turn — `mail-nudge` queues nudge text against an
existing turn, and the UserPromptSubmit hook on interactive mayor
sessions auto-marks unread mail as read on the human's NEXT prompt.
So an interactive mayor sitting idle between human prompts will not
autonomously notice peer replies even after `mail-nudge` fires (see
`docs/cross-city-comms.md` Limitations).

`/loop` plus `ScheduleWakeup` is the only path to autonomous polling
inside an interactive Claude Code session today, and it requires
exactly one human gesture to begin. The detection-and-suggestion
protocol above ensures both mayors prompt their respective humans
the same way at the same moment, so collaborative threads look
intentional rather than ad-hoc.
{{ end }}
