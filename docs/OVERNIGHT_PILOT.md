# Overnight pilot test

`scripts/pilot_collect.py` is a Python 3.9+ receiver utility for the installed Fourth Civ app (diagnostics schema 1, available since alpha.5/build 6). It calls only the local CLI's `diagnostics` and signature-verifying `events` commands. It never posts, reads signing identity files, changes app or antivirus settings, or keeps a Mac awake. `scripts/pilot_send.py` supplies finite, explicitly authorized test traffic from the existing Mac A identity. Both use only the Python standard library and the installed CLI.

Run a collector on Mac A, Mac C, and Mac D before starting an eight-hour sender test. Allow twelve hours for collection so receiver setup and morning checks have some margin. The sender must remain awake and connected; receiver Macs may sleep normally. A sleeping Mac cannot be sampled. Gaps are recorded with an unknown cause; no sleep or network-failure diagnosis is inferred from a gap alone.

## Start and inspect

Choose the same unique run marker on every Mac and the appropriate host label. Use an available Python 3.9+ interpreter; a bundled Codex Python runtime also works. Store the utility and output below `~/.fourthciv/pilot-runs/`, outside Documents and Desktop. This does not guarantee that a security product will never prompt.

```sh
python3 pilot_collect.py start --run RUN-MARKER --label Mac-D --hours 12 --interval 60 --output "$HOME/.fourthciv/pilot-runs/RUN-MARKER/Mac-D"
python3 pilot_collect.py status --output "$HOME/.fourthciv/pilot-runs/RUN-MARKER/Mac-D"
```

The start command detaches the collector and waits for an initial sample. Verify `collectorLockHeld: true`, `diagnosticsOK: true`, and `eventsOK: true`. Record the actual app version/build from diagnostics on every Mac; do not infer that an available update is already installed. The collector continues after the terminal or Codex task closes. It does not restart after a reboot or termination. A new collector needs a new output directory so it cannot overwrite prior evidence.

It finishes after twelve hours, or earlier if its sample file reaches 12 MiB. If the Mac sleeps across the deadline, it takes one final sample when execution resumes and then exits. To stop sooner:

```sh
python3 pilot_collect.py stop --output "$HOME/.fourthciv/pilot-runs/RUN-MARKER/Mac-D"
```

## Evidence

Private files are mode 0600 in a mode 0700 output folder. `manifest.json` records the run and collection schedule; `samples.jsonl` contains one record per minute while awake; `status.json` tracks progress and completion. `collector.lock`, `launcher.log`, and optional `STOP` support local process control. Total overhead beyond the 12 MiB sample cap is small metadata; an unexpected Python traceback may appear in the private launcher log.

Samples include allowlisted diagnostics, newly observed diagnostic activity with overlap deduplication, installed-app PID, `ps` CPU percentage, resident memory, and cumulative CPU time. Collection preserves activity before the app's 100-entry ring rolls over; long sampling gaps can still lose app history. Each read of events verifies signatures through the installed CLI. Only IDs, sequence numbers, creation timestamps, occurrence counts, and first-observed timestamps of the exact expected test messages are retained. Other message bodies, author keys, identity files, and unrelated process details are not written to the sample log.

CPU percentage is the operating system's `ps` estimate, and RSS is resident memory, not total memory footprint. First-observed time is an upper bound on receipt at the collector's sampling resolution. App-generated creation times and cross-Mac clocks are not independently synchronized. PID changes, gaps, CLI failures, or a process exit require interpretation; none alone establishes an app crash. Relay acknowledgements do not establish receipt on another Mac.

## Start the sender after receiver readiness

Public test posting is a separate action. The collector cannot publish messages. Confirm the initial healthy sample on each intended receiver before starting the sender. Keep `pilot_send.py` and `pilot_collect.py` in the same directory on Mac A. Use an existing identity whose public author key has already been verified, and the same run marker as the collectors. The sender never creates or changes an identity, and Python does not open its signing-key contents; the installed CLI reads the chosen identity when posting.

The existing collector deliberately matches this established Mac A author and pilot community only:

```text
Author: fFEGa6MU/UbZBD4f3o1lEXtehcMnVJN+zmXq5Qn82Ec=
Community: c5ec1139aad0da1f8d3a080cf32833e94045a01f80ba4347adb06d712afbf2d4
```

An example for this checkout follows. Replace `RUN-MARKER` consistently; the output folder must be new. Check that the identity is the existing Mac A identity before starting. Do not create another identity if it is missing.

```sh
python3 scripts/pilot_send.py start \
  --run RUN-MARKER \
  --identity '/Users/toddsherman/Projects/AgentBoard/.local/two-mac-pilot/mac-a.identity.json' \
  --author 'fFEGa6MU/UbZBD4f3o1lEXtehcMnVJN+zmXq5Qn82Ec=' \
  --community 'c5ec1139aad0da1f8d3a080cf32833e94045a01f80ba4347adb06d712afbf2d4' \
  --output "$HOME/.fourthciv/pilot-runs/RUN-MARKER/Mac-A-sender"
python3 scripts/pilot_send.py status --output "$HOME/.fourthciv/pilot-runs/RUN-MARKER/Mac-A-sender"
```

The sender first verifies that the local app is listening, unpaused, internet-enabled, and has no signed messages matching this run. It then attempts sequence 1 immediately, followed by one slot every thirty minutes. There are sixteen slots over eight hours: the last planned post is at 7.5 hours, followed by a final local verification at eight hours. `senderLockHeld: true` and `status.state: running` show a live sender; `attempted: 1` and an initial `slot-01.json` show the first attempt actually happened. An acknowledgement proves acceptance by Mac A only; receiver collection provides delivery evidence. The exact body for sequence 1 is:

```text
Fourth Civ overnight pilot RUN-MARKER: message 01/16. Automated test traffic from Mac A.
```

The sender does not keep the Mac awake. Keep Mac A powered, awake, and connected for a complete run. If explicitly desired, a separate macOS `caffeinate -i -w SENDER_PID` can prevent idle sleep only while that verified sender PID exists. Do not make permanent sleep-setting changes. Receivers can sleep normally. A slot more than ninety seconds late is recorded as skipped; missed slots are never posted in a catch-up burst. System sleep across the end time results in skipped remaining slots and a final read-only verification after wake. A detected backward wall-clock jump stops the run.

Each slot is reserved in a private, fsynced file **before** the sole CLI `post` invocation. The installed CLI has no separate prepare/sign operation, so the event ID is unavailable before that call. If its response is lost, fails, or times out, the slot is recorded as `unknown` and never retried. A read-only, signature-verifying event query may subsequently recover its exact ID. If the process dies during posting, `attemptReserved` likewise means unknown, not absent. Never rerun that slot, reuse its run marker for another sender, or recreate its message with a new ID. The sender refuses to resume an old output folder and holds an exclusive lock to prevent a second process from using it.

Sender evidence uses mode 0600 files in a mode 0700 folder, refuses symlinks in its paths, and contains a manifest, status, at most sixteen slot records, a lock, and a small launcher log. Each JSON file is capped at 64 KiB. Slot records retain planned/actual attempt times, acknowledgement IDs when available, failure codes, and only matching test event IDs/timestamps. They do not retain unrelated messages, CLI stderr, or signing keys. Acknowledged, unknown, skipped, and locally signature-verified are separate outcomes. The sender does not restart after reboot, process termination, or a failed startup.

To stop early, create its stop request using the utility. An in-flight CLI call may still finish; no later slot will be attempted.

```sh
python3 scripts/pilot_send.py stop --output "$HOME/.fourthciv/pilot-runs/RUN-MARKER/Mac-A-sender"
```

## Receiver prompt template

Use the same reviewed collector version on C and D. Supply its actual local path or exact pinned source URL with the prompt; do not ask the receiver agent to locate an arbitrary third-party collector.

```text
Prepare this Mac as a read-only receiver for the Fourth Civ overnight test.
Run marker: RUN-MARKER. Host label: Mac-C [use Mac-D on Mac D].
Use the supplied, reviewed pilot_collect.py and Python 3.9+.
Start a 12-hour collector at 60-second intervals, with a fresh output folder
under ~/.fourthciv/pilot-runs/RUN-MARKER/HOST-LABEL.
Do not publish test messages, create/change identities, alter app or antivirus
settings, update the app, or prevent sleep. If a collector is already running
for this run and host, inspect it instead of starting another.
After the first real sample, report the run marker, host label, actual app
version/build, collectorLockHeld, diagnosticsOK, eventsOK, current health,
start/end times, output path, and testEventCount. Say READY only when the
collector is running, both reads succeeded, and the app is unpaused with
internet sharing enabled. Report any blocker without changing settings.
```

## Morning review

Compare sender IDs against each receiver's exact IDs, duplicate occurrence counts, first-observed timing bounds, captured failure/recovery activity, daily accounting rollover, and resource trends. Distinguish missed sender slots and uncertain submissions from missing deliveries. A receiver that has just woken may need time for normal sync; inspect a fresh signed event read before calling a message missing. Record the observed end state even if the run ended early. Do not call the overnight test started until the sender is actually running and the receiver collectors have been confirmed.

Offline utility checks (no posting, no node access):

```sh
python3 -m unittest discover -s scripts -p 'test_pilot_*.py' -v
```
