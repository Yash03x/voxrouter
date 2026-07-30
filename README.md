# voxrouter

**Talk to your Mac; it codes.** A voice assistant that dispatches tasks to
Claude Code or Codex — whichever still has quota — and moves a task to the other
engine mid-run if the first one runs out.

Hold a key, say *"run the tests and fix what breaks"*, and it transcribes
on-device, picks an engine, runs it headless, and tells you when it's done.

- **Quota-aware routing.** Reads live usage and picks the engine with headroom,
  with hysteresis so it doesn't thrash between them.
- **Survives running out.** A task that dies at 80% on one engine continues on
  the other, with a journal of what was already done.
- **Remembers.** "Run the tests" → "now fix those failures" works.
- **Fully on-device speech.** No API keys, no network, nothing leaves the Mac.
- **Menu bar app** with live status, quota, and conversation history.

Requires macOS 26+ (speech), Swift 6, [OpenUsage](https://www.openusage.ai) for
quota, and at least one of Claude Code / Codex installed.

> **Status:** built and used daily by its author, but young. The wake word isn't
> implemented yet — activation is push-to-talk. Interfaces may change.

## Status

| Layer | State |
|---|---|
| Quota reading (OpenUsage) | **done**, verified against live data |
| Engine routing with hysteresis | **done**, 20 tests |
| Headless dispatch + streaming | **done**, verified end to end through codex |
| Cross-engine failover + handoff journal | **done**, 9 integration tests |
| Conversation memory across commands | **done** — see [Conversation memory](#conversation-memory) |
| Audio tap + VAD + segmentation | **done**, 23 tests, verified on live mic — but see [VAD limits](#vad-limits-measured) |
| Push-to-talk (⌃⌥Space) | **done**, 15 tests; registration verified live, key delivery needs a human finger |
| Speech-to-text | **done**, on-device, ~15× realtime — see [Speech](#speech-to-text) |
| Text-to-speech | **done**, 24 tests — see [Speaking back](#speaking-back) |
| Voice mode (hold key → speak → dispatch → spoken reply) | **done** — `voxrouter voice` |
| Menu bar app + history window | **done** — see [The app](#the-app) |
| Projects + Anywhere scope | **done** — see [Projects](#projects) |
| Undo / recovery point | **done** — see [Undo](#undo) |
| Local commands, Shortcuts, notes, timers | **done**, 30 tests — see [Things it answers itself](#things-it-answers-itself) |
| Wake word | **not built** — see [Roadmap](#roadmap) |
| Proactive notifications | **not built** — see [Roadmap](#roadmap) |

## How engine selection works

Quota comes from [OpenUsage](https://www.openusage.ai)'s local HTTP API:

```bash
curl -s http://127.0.0.1:6736/v1/usage | jq .
```

That endpoint is an internal surface for OpenUsage's own widget, not a published
contract (verified against 0.7.7-beta.1). Every field is treated as optional and
unknown row types are ignored; if the schema drifts, `QuotaSnapshot.isDegraded`
trips and routing falls back to preference order rather than reading a missing
quota as 0% used.

A provider is considered as available as its **most-constrained window** — for
Claude that's the tighter of Session (5h) and Weekly, for Codex the Weekly.

Routing is deliberately **sticky**. Picking "whoever has the most headroom" looks
right and behaves badly: engines trade places on every refresh and each switch
costs a context handoff. Instead:

- Stay on the current engine while it's under `highWater` (85%).
- Above that, switch to an engine under `lowWater` (70%) — or to anything at
  least `minimumSwitchGain` (15 points) cooler, so a dying engine at 95% still
  yields to one at 75%.
- Never dispatch above `hardCeiling` (97%).
- If nothing is better, keep going and flag the decision as a compromise.

Quota is polled on a background interval and read from memory, so routing never
puts a network round trip in front of a spoken command.

### Three reasons to hand off — and one not to

| situation | failover? | why |
|---|---|---|
| out of quota | yes | the other engine has quota |
| engine unusable (expired login, broken install) | yes | the other engine still works |
| task failed (compile error, bad request) | **no** | it will fail identically elsewhere, burning quota |

The middle row exists because of a real incident: `claude` was installed but its
OAuth session had expired, so it printed "Failed to authenticate" and exited 1.
That was classified as a task failure, so nothing failed over and the user was
blocked — while a healthy Codex sat idle.

### Classify structurally, never by substring

Failures are read from protocol fields, not by matching text against JSON. Text
sniffing is reserved for plain-text output.

This is load-bearing. Claude emits a `rate_limit_event` on **healthy** runs
carrying `status: "allowed"`; a substring matcher saw `rate_limit` and declared
a quota failure, so a *completed* Claude run was discarded and re-done on Codex —
double quota spend on every task. Bare status codes ("429", "401") were removed
from the patterns for the same reason: they collide with token counts, byte
sizes and ids.

### Two layers of failover

Proactive routing isn't enough on its own: OpenUsage refreshes upstream roughly
every 5 minutes, so a real 429 can arrive while quota still reads healthy. So
engine output is also sniffed for limit errors, and a real one immediately
sidelines that engine locally and re-routes — without waiting for the dashboard
to catch up.

## The app

```bash
./Scripts/build-app.sh
open build/VoxRouter.app
```

A menu bar item — no Dock icon, no app menu (`LSUIElement`). Clicking it opens a
panel with live status, quota bars, and recent activity; **History** opens a
window listing past conversations with every turn, its engine, and the run id
that links back to the on-disk journal.

The icon tells you what it's doing without opening anything: it changes symbol
per state and **pulses only while something is actually happening** — listening,
transcribing, or working. A menu bar item that pulses permanently is the kind of
thing people uninstall software over.

Quota bars use the same thresholds as the router (green under 85%, orange to
97%, red above), so a colour means what the router means.

### It has to be a bundle

SwiftPM produces a bare executable, and macOS will not grant microphone access
to one — TCC identifies apps by bundle id and code signature. `build-app.sh`
assembles the bundle by hand and ad-hoc signs it, giving a stable identity
(`dev.voxrouter.app`) so the microphone grant survives relaunches.

It's a **new identity**, separate from your terminal, so it prompts for the
microphone once on first launch even if the CLI already had access.

### The speech model is per-identity too

This one is easy to lose an evening to. `AssetInventory` scopes the on-device
speech model to the **requesting app's identity**, so a model installed by
`voxrouter transcribe --install` does *not* count for `dev.voxrouter.app`:

```
CLI (terminal identity):     model status: installed
App (dev.voxrouter.app):     model status: supported (not installed)
```

Startup then stopped at the model check with no window, no output and no log —
indistinguishable from a crash. Worse, the error told the user to run the CLI
command, which cannot fix it.

Now: `build-app.sh` installs the app's own model as part of the build, the app
offers a one-click download if it's still missing, and there's a diagnostic that
reports each precondition separately instead of hanging:

```bash
build/VoxRouter.app/Contents/MacOS/VoxRouter --diagnose
build/VoxRouter.app/Contents/MacOS/VoxRouter --install-model
```

To start it at login: System Settings ▸ General ▸ Login Items ▸ + ▸
`build/VoxRouter.app`.

### Why AppKit, not `MenuBarExtra`

Only Command Line Tools are installed here, and `libSwiftUIMacros.dylib` ships
with full Xcode — so `@State`, `@Bindable` and `@Observable` cannot expand, and
neither can `@main`. The views therefore use the pre-macro `ObservableObject` /
`@ObservedObject` API, and the lifecycle is AppKit (`NSStatusItem`, `NSPopover`,
top-level code in `main.swift`). This also happens to be better for the icon
animation: the status item is animated directly, so it keeps pulsing whether or
not the panel is open.

## Projects

Tasks run in the **active project**. Pick it from the menu bar, or say so:

> *"switch to torrent client"* → **"Switched to torrent-client."**

Spoken names are matched loosely, because speech gives you "torrent client"
while the directory is `torrent-client`. Partial names work too — "vox" finds
`voxrouter`.

Switching requires an explicit verb (`switch to`, `work in`, `go to`). A project
name inside an ordinary request — *"add tests to voxrouter"* — is part of the
task, not a command to change scope. Otherwise normal work would silently move
you somewhere else.

Conversation memory is per-directory, so switching projects also switches
history: each project remembers its own thread.

Add projects from the menu (**Add Project…**) or in the config:

```json
"projects": [
  { "id": "vox", "name": "voxrouter", "path": "/Users/you/code/voxrouter", "isAnywhere": false }
],
"activeProjectID": "vox"
```

### Anywhere

There's always an **Anywhere** entry, which starts at your home directory rather
than in a project. It's a visible, named choice rather than a hidden mode:
whether a task can reach the whole Mac shouldn't be something you have to infer
from a path. The menu bar shows a globe icon when it's active.

Worth being clear about what scoping does and doesn't do: the active project is
**where the agent starts, not a boundary**. With approval prompts disabled,
Claude Code can `cd` anywhere regardless — it has no filesystem sandbox. Only
Codex can be genuinely confined, via `--sandbox workspace-write`. Projects make
the intended scope explicit; they don't enforce it.

The picker also flags a project that isn't a git repository, since Codex refuses
to run in one — better to see that before a task fails.

## Things it answers itself

Not everything deserves an agent. Dispatching *"what's my quota"* to Claude Code
takes about twenty seconds and spends quota to answer a question the app already
knows. A local command layer runs before dispatch and handles what it can:

| Say | What happens |
| --- | --- |
| *"what's my quota"* | Reads the monitor already running — instant, no engine |
| *"note down the lease renews in March"* | Appends to `~/.local/state/voxrouter/notes.md` |
| *"what are my notes"* | Reads the last few back |
| *"turn off the lights"* | Runs the shortcut of that name |
| *"run water eject"* | Same, said explicitly |
| *"what shortcuts do I have"* | Counts them, names a few |
| *"set a timer for five minutes"* | Speaks up when it's done — survives a restart |
| *"what timers do I have"* | How long is left |
| *"cancel the timer"* | Cancels every pending one |
| *"volume up"*, *"mute"*, *"set volume to 30"* | Adjusts output |
| *"open Safari"* | Launches it |
| *"say that again"* | Repeats the last reply |
| *"what can you do"* | Lists the above |

Anything else goes to an engine, unchanged.

### The Shortcuts bridge is the whole integration story

One bridge instead of one integration per app. Shortcuts already holds the
permissions for Calendar, Reminders, Notes, Music, Home and the rest, so running
a shortcut asks *Shortcuts* to act rather than requesting those grants
ourselves — and every shortcut you make later is voice-callable with no code
change here.

### Claiming an utterance requires the target to exist

"Run" and "open" are two of the commonest verbs in a coding request. An earlier
version matched on the verb alone, so *"run the tests and fix what breaks"* was
taken as a shortcut name and never reached an engine — the task vanished with a
cheerful reply. A local command now claims an utterance only when the shortcut
or app it names actually exists.

The same reasoning removed bare *"note"*: *"note the retry logic is wrong and fix
it"* is a task. `note down`, `note that` and `remember that` state the intent to
record; plain `note` doesn't. The asymmetry is deliberate — a note that reaches
an engine costs a little quota, while a task captured as a note is lost silently.

Saying a shortcut's exact name runs it, but a sentence that merely *contains*
one doesn't: *"log a film about the trip to Japan"* is not the `Log a film`
shortcut.

### Timers outlive the app

They were a `Task` sleeping in memory, so quitting the app — or letting it be
relaunched at login — dropped every pending timer without saying so. A timer
you were *told* was set and that then silently never fires is worse than one
that was refused, because you stop checking.

Pending timers are written to `~/.local/state/voxrouter/timers.json` and
re-armed at launch on their **remaining** time, so a restart doesn't extend
them. One that came due while the app was closed is announced as missed rather
than dropped — that's the whole point — unless it's more than an hour stale, at
which point saying anything would just teach you to ignore it.

Persisting them is also what makes *"cancel the timer"* necessary. A
mistranscribed "eight hours" used to die with the app; now it would follow you
across every restart.

Both the app and the CLI write that file, so the file — not an in-memory copy —
is the record of what exists, and every read-modify-write happens inside an
advisory `flock`. Locking only the *write* wouldn't have been enough: the stale
read is the problem, so the read has to be inside the lock too.

Measured with twelve processes racing to add a timer, all alive at once inside a
118 ms window:

| | timers surviving out of 12 |
| --- | --- |
| Without the lock | 2, 7, 6 |
| With the lock | 12, 12, 12 |

Two details that matter:

- **The lock is a separate file** from the data it guards. Atomic writes replace
  a file by renaming a temporary over it, which swaps the inode — a lock taken
  on the data file would be held on an inode nobody else can see, and every
  process would believe it had exclusive access.
- **Waiting is bounded** (2 s), and the work runs either way. A held lock means
  another process is mid-write, which takes microseconds; if it ever takes
  longer, that process is wedged, and blocking the voice pipeline behind it
  would turn one stuck process into a stuck assistant. Same lesson as never
  SIGKILLing a running shortcut.

### Never kill a running shortcut

`shortcuts run` can take a while — `Water Eject` plays a tone for half a minute
— so waiting on it forever would wedge the voice pipeline. The first fix was a
timeout that killed the process, and it was worse than the problem: SIGKILLing
`shortcuts run` mid-request left the system's shortcut service so wedged that
*every* subsequent run hung, CLI and AppleScript alike, until the service was
restarted.

So the deadline is only about when to stop *waiting*. After 12 seconds it says
"Water Eject is running" and lets it finish; a stuck one gets SIGTERM after five
minutes, never SIGKILL.

Failures speak the CLI's own message rather than a generic one, because it's
usually the actionable part — *"This action requires Letterboxd to be
installed"* tells you what to fix, where "it didn't finish" never could.

## Undo

Every task in a git repository records where the repository was before it ran.

> *"undo that"* → **"That would undo … and reset to commit 9506651b. Say yes to confirm."**

Or from the CLI:

```bash
voxrouter undo          # shows what it would do
voxrouter undo --yes    # does it
```

This matters most with approval prompts disabled: an agent acting on a misheard
instruction changes files immediately and without asking, so the recovery point
has to exist *before* it starts rather than be wished for afterwards.

Three properties worth knowing:

**Capturing never touches your working tree.** It uses `git stash create`, which
writes a commit object and changes nothing else — no `git stash`, no moving your
changes out from under yourself or the agent, and nothing added to `git stash
list`. Snapshots live under `refs/voxrouter/` so garbage collection can't drop
them and your stash list stays yours.

**Uncommitted work is restored too.** If you had unsaved edits when the task
started, undo brings them back — losing your own work while undoing the agent's
would be worse than not undoing at all.

**Undo is itself reversible.** It anchors whatever it's about to discard before
resetting, and tells you the ref:

```
↩︎ reset to 9506651b
  restored your uncommitted changes
  undone work kept at refs/voxrouter/snapshots/undone-20260730-193213-7705
```

An undo you can't reverse is just a different way to lose work. Note the
anchoring handles the case where the agent *committed*: the tree is then clean,
`stash create` returns nothing, and the commits themselves are what's being
thrown away — so HEAD is anchored directly rather than trusting the reflog not
to expire.

Spoken undo is matched as a whole utterance only. *"undo that change to the
parser"* is work for the engine, not a request to reset the repository.

## Conversation memory

Commands are not one-shots. "Run the tests" followed by "now fix those failures"
works, because each turn is remembered per working directory.

Continuity comes in two strengths, and the stronger is preferred:

1. **Session resume** — when the follow-up routes to the *same* engine, its own
   session id is passed to `--resume`. True continuity: the model still holds
   its full context, and nothing has to be restated.
2. **Context preamble** — across an engine boundary no session can be resumed,
   so a compact digest of recent turns (requests and outcomes, not transcripts)
   is prepended instead. Weaker, but it's the best available.

Verified end to end: asked for a line count (3), then two turns later "multiply
the number you first told me by ten" → **30**, with all turns sharing one session
id. That number existed only in the conversation.

Conversations are scoped per directory — two projects are two conversations —
and expire after `conversationTimeout` (default 30 min), because a long silence
means you've moved on and inheriting a stale task is worse than starting clean.

To start fresh: `voxrouter run --new <task>`, or say "start over" / "new task" /
"forget that" as a complete utterance. (A reset phrase *inside* a longer request
— "start over from the top of the file" — is treated as the request it is.)

## The handoff journal

This is the part that makes switching survivable.

Neither engine's native resume crosses the boundary to the other: if Claude dies
at 80% of a task, `codex exec resume` knows nothing about it. So the
authoritative record lives outside both engines, in
`~/.local/state/voxrouter/runs/<run-id>/`:

- `journal.md` — human-readable log
- `manifest.json` — task, engine history, outcome
- `entries.json` — structured events

On failover the replacement engine gets the original task, a transcript of what
the previous engine actually did, and an instruction to verify state on disk
before editing — because the previous engine may have left a change
half-applied, and the log can't be trusted over the filesystem.

Be clear about what this is: a **reconstruction, not a continuation**. Codex
genuinely cannot load Claude's session, so a summary is the ceiling here. Within
one engine, [conversation memory](#conversation-memory) resumes the real session
instead.

Actions are logged with their arguments, which is what makes the reconstruction
usable:

```
action: Bash: wc -l < words.txt
action: Read: convo-test/words.txt
```

They were once logged as bare tool names — a replacement would read "it used
Bash three times" and learn nothing. Bulk content (file bodies, `old_string`) is
still omitted deliberately: it would bury the log, and a replacement should read
the file rather than trust a transcript of it.

Protocol chatter is excluded on purpose, and Claude's closing message is
de-duplicated (it arrives twice — streamed, then in the final result).

## Audio

`MicrophoneSource` taps `AVAudioEngine`, resamples once to 16 kHz mono (what
every on-device recogniser here wants), and re-chunks into exact 30 ms frames —
the device delivers arbitrary buffer sizes and the VAD's thresholds are
meaningless without uniform frames.

`VoiceGate` is a pure state machine: frame in, decision out, no audio
dependency, so its whole behaviour is testable on synthetic signals. It uses
frame energy (vDSP), zero-crossing rate, and an adaptive noise floor.

The noise floor is the **median of a 3 s sliding window, sampled only while the
gate is shut**. An exponential average has to be told when *not* to learn
("only when it's quiet"), which is circular — that decision depends on the floor
being estimated. Sampling only while shut makes the window background by
construction, so its median is the room level. The estimate is clamped at
-30 dBFS, because if the process starts mid-sentence the window is all speech
and the median would land on the speaker, leaving the gate permanently deaf.

`SpeechSegmenter` adds the **preroll buffer**, which is the reason it exists
rather than piping the gate straight into a recogniser: the gate needs ~90 ms of
speech before it opens, and a wake word's first phoneme is exactly what got it
there. Without preroll the recogniser receives "ey router" and the match fails.

Check it live:

```bash
voxrouter listen ~/Desktop/segments
```

Shows a level meter and reports each detected utterance, saving them as WAVs so
you can confirm by ear that the preroll captured the start of the word.

### VAD limits (measured)

Measured over 45 s in a real room with the machine idle, the level distribution
was p50 −55 dBFS, p90 −31, p99 −24, with peaks to −12. Roughly 10% of frames
carry speech-amplitude sound that is not speech.

That produced ~4 false triggers per 45 s. **No threshold setting fixes this**:
rejecting a −12 dBFS event would also reject actual speech, because the
difference between them is spectral and temporal structure, not level. Two
rounds of tuning are already in — a median floor instead of a low percentile, and
a `minPeakDb` gate that eliminated the faint (−38 to −52 dBFS) false positives —
and this is where the energy-based approach genuinely runs out.

This is survivable by design: the gate's only job is deciding when to wake the
recogniser, and the wake-word match rejects a false wake. The cost is wasted
transcriptions, not wrong answers. But ~5/min is more ANE wakeups than an
always-on daemon should want, so **swapping in Silero VAD is the recommended
next step** — a small trained model that discriminates on structure. The
`VoiceGate` interface (frame in, decision out) is already the right shape for it.

## Push-to-talk

```bash
voxrouter ptt ~/Desktop/clips
```

Hold **⌃⌥Space**, speak, release. Clips are saved as WAVs.

Three decisions worth knowing:

**The chord is changeable.** ⌃⌥Space by default, but plenty of apps own it
(Alfred, Raycast, input-source switching). If it's taken, VoxRouter falls back
through ⌃⌥V, ⌥Space, ⌃⌥D and ⌃⇧Space automatically and tells you which it
landed on; the menu bar panel has a picker to choose directly. Registering a
chord and reporting "it is taken" to someone with no way to change it would
leave them unable to use the app at all.

**The chord, not the keyboard's mic key — because that key can't be had.**

This was tested properly rather than assumed. With Accessibility granted and a
consuming `CGEventTap` installed at `.headInsertEventTap`, pressing the
microphone key produces **no event at all**. macOS claims it below the layer a
session tap can reach, so no permission and no tap ordering recovers it. Same
for using it while keeping Siri — the question doesn't arise, since nothing
reaches us either way.

A plain key+modifier chord goes through Carbon's `RegisterEventHotKey`, which
needs **no permissions**, cannot be shadowed, and reports key-**release** —
which `NSEvent`-based approaches make awkward and hold-to-talk requires.

If you want to check what a given key emits on your machine:

```bash
voxrouter keys      # press a key; it intercepts nothing while identifying
```

**The microphone runs continuously.** Starting `AVAudioEngine` costs 100–300 ms,
which would swallow the first syllable of every command. So the engine is warmed
at launch and a press is merely a mark in a ring buffer — which makes 300 ms of
preroll free. People start talking as they press, not after.

**Push-to-talk never consults the VAD.** When you've said "record now",
second-guessing that with a voice-activity detector can only be wrong. This path
is immune to everything in [VAD limits](#vad-limits-measured) — which is why it's
the more reliable half of the voice layer.

`voxrouter ptt` runs as an `.accessory` app: Carbon hotkeys are only dispatched
to a process the window server treats as an application, so a plain
`CFRunLoopRun()` in a CLI registers the hotkey and then never sees an event.

## Speech-to-text

On-device via `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+) behind the
`Transcriber` protocol, so Parakeet-MLX or whisper.cpp is a new conformance
rather than a rewrite. No network, no API key, nothing leaves the machine.

One-time model download:

```bash
voxrouter transcribe --install
```

Note `SpeechTranscriber.installedLocales` and
`AssetInventory.status(forModules:)` disagree — a locale can appear "installed"
while the module's own assets are not. The status check trusts the latter.

Then the whole thing joined up:

```bash
voxrouter voice
```

Hold **⌃⌥Space**, say what you want done, release. It transcribes, routes to
whichever engine has quota, and runs it. `--dry-run` transcribes and shows the
routing decision without executing anything.

### Accuracy (measured)

Plain English is excellent — "Run the test suite and report the failures"
transcribed verbatim at ~15× realtime (0.14 s for 2.4 s of audio).

Developer vocabulary is the weak spot. Against synthesised speech:

| said | heard |
|---|---|
| git rebase | **get** rebase |
| OAuth handler | **Ooff** handler |
| Kubernetes | **Cubernet's** |
| hysteresis | **historesis** |
| dereference | **D-reference** |

`AnalysisContext.contextualStrings` biasing is wired up
(`TechnicalVocabulary`), and **it made no measurable difference** — A/B runs
with and without produced byte-identical transcripts, including for
"Kubernetes", which is in the hint list. Either the hints aren't consulted in
this configuration, or synthesised speech genuinely sounds like the wrong word.
A/B it yourself against a real voice:

```bash
voxrouter transcribe recording.wav --no-vocab
```

If real speech is no better, this is the concrete case for swapping the
`Transcriber` backend — which is exactly what the protocol is for.

## Speaking back

```bash
voxrouter say "your text here"     # shows what the narration filter does to it
voxrouter say --voices             # installed English voices
voxrouter voice --mute             # run without spoken replies
```

Uses `AVSpeechSynthesizer`, not the `say` binary. Same system voices, but
in-process — no fork/exec per utterance, and `stopSpeaking(at: .immediate)` cuts
off mid-word, which is what barge-in needs. Killing a `say` process and waiting
for the audio device to be released is neither instant nor reliable.

Set `"voice"` in the config to any name from `--voices` (e.g. `"Samantha"`).

### It says very little on purpose

An engine emits dozens of tool calls per task. Narrating them would make an
always-on assistant intolerable, so speech is reserved for the four moments that
change what you'd do next:

| moment | spoken |
|---|---|
| dispatched | "Working on it with Claude." |
| failover | "Switching to Codex; the other one ran out of quota." |
| finished | "Done." + a filtered summary |
| failed / out of quota | the reason, and when quota returns |

Tool calls and streamed prose are silent.

Engine replies are also written to be *read*, so `SpokenNarration.speakable`
strips what doesn't work aloud — code fences are dropped entirely, paths are
reduced to filenames, markdown and URLs are removed, and long text is truncated
on a sentence boundary. The screen still has the full text.

```
in:  Fixed the leak in Sources/Audio/VoiceGate.swift. See `prewarm` for details.
out: Fixed the leak in VoiceGate.swift. See prewarm for details.
```

### Latency

The first utterance in a process costs ~555 ms of synthesizer warm-up on top of
the audio itself; later ones cost only their audio length. `voice` pays that at
launch via `prewarm()`, so the first reply isn't the slow one. Measure it:

```bash
voxrouter say --bench "Done."
# prewarm 555 ms · after prewarm 597 ms · repeat 597 ms
```

Barge-in is wired to the push-to-talk key: the instant it goes down, speech
stops. Being talked over is the fastest way to make an assistant annoying.

## Install

### Download

```bash
curl -L https://github.com/Yash03x/voxrouter/releases/latest/download/VoxRouter-macos-arm64.zip -o /tmp/vox.zip \
  && ditto -x -k /tmp/vox.zip /Applications \
  && xattr -dr com.apple.quarantine /Applications/VoxRouter.app \
  && open /Applications/VoxRouter.app
```

That downloads it, installs it, clears the quarantine flag, and launches it.

**Why the `xattr` line is needed.** The app is signed, but with a self-signed
certificate rather than an Apple Developer ID, so Gatekeeper refuses anything
downloaded from the internet. Removing the quarantine flag is the standard
workaround. If you'd rather not do that for a tool that runs shell commands —
entirely reasonable — [build from source](#build-from-source) instead; locally
built apps are never quarantined and it takes about 30 seconds.

Getting rid of the warning properly requires a paid Apple Developer ID
($99/year); the tooling for it is already in place, see
[Scripts/RELEASING.md](Scripts/RELEASING.md).

### What you need

| | |
|---|---|
| **Apple Silicon Mac** | the release is arm64 only |
| **macOS 26+** | for on-device speech |
| **Claude Code and/or Codex** | installed *and logged in* — one is enough |
| **[OpenUsage](https://www.openusage.ai)** | optional; without it routing falls back to a fixed preference order instead of live quota |

### Build from source

Requires macOS 26+ (for on-device speech), Swift 6, and
[OpenUsage](https://www.openusage.ai) running for quota data.

```bash
git clone https://github.com/Yash03x/voxrouter.git
cd voxrouter
./Scripts/build-app.sh          # menu bar app
swift build -c release          # CLI only
```

If something misbehaves, this reports every precondition separately:

```bash
build/VoxRouter.app/Contents/MacOS/VoxRouter --diagnose
```

Codex works out of the box — it's found on `PATH`, or falls back to the
`codex-cli` bundled inside `ChatGPT.app`. Claude Code needs its CLI:

```bash
npm i -g @anthropic-ai/claude-code
```

Check what's wired up:

```bash
.build/release/voxrouter engines
```

## Usage

```bash
voxrouter quota        # live quota for every enabled provider
voxrouter engines      # which engine binaries are installed
voxrouter route        # which engine would be chosen right now, and why
voxrouter run <task>   # dispatch a task, failing over on quota limits
voxrouter run --new <task>   # ...starting a fresh conversation
voxrouter ask <phrase> # what the voice pipeline would do with this, no mic
```

`ask` is the quickest way to check whether a phrase is handled locally or would
be sent to an engine:

```bash
voxrouter ask "run the tests and fix what breaks"
```

`VOXROUTER_CWD` overrides the working directory for a single run.

## Configuration

Optional, at `~/.config/voxrouter/config.json`. Defaults are in
`Config.default`; a malformed file logs and falls back rather than stopping an
always-on daemon from starting.

```json
{
  "openUsageBaseURL": "http://127.0.0.1:6736",
  "quotaRefreshInterval": 20,
  "workingDirectory": "/Users/you/code/some-project",
  "routing": {
    "preferenceOrder": ["claude", "codex"],
    "highWater": 85,
    "lowWater": 70,
    "minimumSwitchGain": 15,
    "hardCeiling": 97,
    "blindCooldown": 1800
  },
  "engineArgs": { "codex": [] }
}
```

`engineArgs` appends flags to an engine's invocation. Note that
`--skip-git-repo-check` is **not** passed to codex by default: codex refuses to
run in an untrusted directory, and that guard is worth keeping. Add it here if
you specifically want it.

### Confirmation on destructive requests

Speech recognition mishears. With approval prompts disabled (below), the engine
acts on the mishearing immediately and irreversibly — so requests that could
destroy work are spoken back and require a spoken "yes" before running:

> *"delete everything in the project"*
> → **"That would delete everything. Hold the key and say yes to confirm."**

It fires on inherently dangerous operations (`rm -rf`, force push,
`reset --hard`, `drop database`, `sudo`) and on destructive verbs aimed at broad
targets. It deliberately stays quiet for routine work like *"delete the unused
import"* — confirming everything would just train you to say yes reflexively,
which is worse than not asking.

An ambiguous reply counts as "no": if the recogniser mishears the confirmation
too, the safe reading is decline. Confirmations expire after 60 seconds so a
later "yes" can't run a forgotten task.

### Running without approval prompts

A voice dispatcher can't answer an interactive approval prompt — there's nobody
at the keyboard to say yes — so a task that triggers one just stalls. Both CLIs
have a flag for this:

```json
"engineArgs": {
  "claude": ["--dangerously-skip-permissions"],
  "codex":  ["--dangerously-bypass-approvals-and-sandbox"]
}
```

**Understand what this means before enabling it.** The agent will run any
command it decides on, with no confirmation, triggered by speech recognition
that can mishear you. Codex has a real filesystem sandbox
(`--sandbox workspace-write` confines it to the working directory), but **Claude
Code does not** — bypassing its permissions is unrestricted, machine-wide, not
just within `workingDirectory`.

A middle ground that still works hands-free is to sandbox Codex and leave Claude
prompting, or to point `workingDirectory` at a scratch repo. When any bypass flag
is set, the menu bar panel shows an **unrestricted** badge, because it's easy to
forget it's on.

### Choosing models

The app's ENGINES section has a per-engine model picker, or set it directly:

```json
"engineModels": { "claude": "opus", "codex": "gpt-5.1-codex-max" },
"engineModelChoices": { "codex": ["gpt-5.1-codex-max", "gpt-5.1-codex-mini"] }
```

### Why "Opus (latest)" and "Opus 5" are both listed

They resolve to the same model *today* — measured against the CLI, `opus` →
`claude-opus-5`, exactly what `opus-5` gives. The difference is what happens
next: the bare alias follows each new release, the pinned one never moves. Pick
the tracking alias to always get the newest, or a pinned version when you want
the same model in six months.

### The list keeps itself current

Neither CLI can enumerate its models — there is no `claude models` — so the
names are read out of the binaries themselves. That runs in the background at
launch and is cached against each binary's size and modification date, so a CLI
update invalidates it exactly when it should. A cold scan is about 3s per
245 MB binary; a cached read is ~10ms.

Discovered names are *merged* with the built-in list, never substituted, so a
failed scan costs nothing rather than emptying the picker. They're deduplicated
by display name, because discovery finds both `opus-4-5` and `opus45` — two
spellings of one model.

```bash
voxrouter catalog   # rescan now and print the resulting menu
```

Claude accepts the aliases `opus`, `sonnet`, `fable` or a full model name. Codex
model names can't be enumerated from its CLI, so the picker offers whatever is in
your `~/.codex/config.toml` plus anything you list in `engineModelChoices`.
Leaving a model unset follows each CLI's own configuration.

## Roadmap

The voice layer, in the order it should be built:

1. ~~**Audio tap + VAD gate.**~~ Done. Optionally revisit with Silero VAD — see
   [VAD limits](#vad-limits-measured) for the measurement that motivates it.
2. ~~**Push-to-talk chord.**~~ Done — see [Push-to-talk](#push-to-talk).
   **Wake word** is what remains here: matched fuzzily against the gated
   transcript. Avoid a phrase starting with "hey" — "Hey Siri" is enabled by
   default on macOS and a shared opening risks cross-triggering whichever
   assistant hears it first.
3. **Transcriber.** Apple's on-device `SpeechAnalyzer` (macOS 26+) behind a
   `Transcriber` protocol, so Parakeet-MLX or whisper.cpp can be swapped in by
   config if accuracy on code identifiers disappoints.
4. ~~**Speaker.**~~ Done — see [Speaking back](#speaking-back).
5. ~~**Menu bar app.**~~ Done — see [The app](#the-app).
6. ~~**Local command layer.**~~ Done — see
   [Things it answers itself](#things-it-answers-itself).

Deliberately not built yet:

- **Wake word**, per item 2 above.
- **Proactive notifications** — speaking up unprompted (a quota window about to
  reset, a long task finishing while you're in another app). The hard part isn't
  the trigger, it's earning the interruption; an assistant that talks when you
  didn't ask gets muted permanently after about two false positives.

### Design note: this is a dispatcher, not a chatbot

Voice UX expects sub-second responses; Claude Code and Codex turns run 30 s to
10 min. Trying to make it conversational would feel broken. The interaction model
is: speak a task, hear "on it", work happens in the background, get told when
it's done.

## Development

```bash
swift test
```

57 tests, no external dependencies. Two notes for a Command-Line-Tools-only
machine (no full Xcode): there is no XCTest, so these use swift-testing, and
`Package.swift` adds the plugin path and rpaths that CLT doesn't wire up itself.
