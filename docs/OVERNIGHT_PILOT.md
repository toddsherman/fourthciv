# Overnight pilot collection

`scripts/pilot_collect.py` is a temporary Python 3.9+ test utility for the installed alpha.5 app. It does not require a new app release. It calls only the local CLI's `diagnostics` and signature-verifying `events` commands. It never posts, reads signing identity files, changes app or antivirus settings, or keeps a Mac awake.

Run a collector on Mac A, Mac C, and Mac D before starting an eight-hour sender test. Allow twelve hours for collection so receiver setup and morning checks have some margin. The sender must remain awake and connected; receiver Macs may sleep normally. A sleeping Mac cannot be sampled. Gaps are recorded with an unknown cause; no sleep or network-failure diagnosis is inferred from a gap alone.

## Start and inspect

Choose the same unique run marker on every Mac and the appropriate host label. Use an available Python 3.9+ interpreter; a bundled Codex Python runtime also works. Store the utility and output below `~/.fourthciv/pilot-runs/`, outside Documents and Desktop. This does not guarantee that a security product will never prompt.

```sh
python3 pilot_collect.py start --run RUN-MARKER --label Mac-D --hours 12 --interval 60 --output "$HOME/.fourthciv/pilot-runs/RUN-MARKER/Mac-D"
python3 pilot_collect.py status --output "$HOME/.fourthciv/pilot-runs/RUN-MARKER/Mac-D"
```

The start command detaches the collector and waits for an initial sample. Verify `collectorLockHeld: true`, `diagnosticsOK: true`, and `eventsOK: true`. The installed app should report alpha.5/build 6. The collector continues after the terminal or Codex task closes. It does not restart after a reboot or termination. A new collector needs a new output directory so it cannot overwrite prior evidence.

It finishes after twelve hours, or earlier if its sample file reaches 12 MiB. If the Mac sleeps across the deadline, it takes one final sample when execution resumes and then exits. To stop sooner:

```sh
python3 pilot_collect.py stop --output "$HOME/.fourthciv/pilot-runs/RUN-MARKER/Mac-D"
```

## Evidence

Private files are mode 0600 in a mode 0700 output folder. `manifest.json` records the run and collection schedule; `samples.jsonl` contains one record per minute while awake; `status.json` tracks progress and completion. `collector.lock`, `launcher.log`, and optional `STOP` support local process control. Total overhead beyond the 12 MiB sample cap is small metadata; an unexpected Python traceback may appear in the private launcher log.

Samples include allowlisted diagnostics, newly observed diagnostic activity with overlap deduplication, installed-app PID, `ps` CPU percentage, resident memory, and cumulative CPU time. Collection preserves activity before the app's 100-entry ring rolls over; long sampling gaps can still lose app history. Each read of events verifies signatures through the installed CLI. Only IDs, sequence numbers, creation timestamps, occurrence counts, and first-observed timestamps of the exact expected test messages are retained. Other message bodies, author keys, identity files, and unrelated process details are not written to the sample log.

CPU percentage is the operating system's `ps` estimate, and RSS is resident memory, not total memory footprint. First-observed time is an upper bound on receipt at the collector's sampling resolution. App-generated creation times and cross-Mac clocks are not independently synchronized. PID changes, gaps, CLI failures, or a process exit require interpretation; none alone establishes an app crash. Relay acknowledgements do not establish receipt on another Mac.

## Sender plan

Public test posting is a separate action. This collector cannot publish messages. The planned sender uses Mac A's existing pilot identity and community, with one message every thirty minutes for eight hours, at most sixteen total. All collectors must share the run marker. The exact body for sequence 1 is:

```text
Fourth Civ overnight pilot RUN-MARKER: message 01/16. Automated test traffic from Mac A.
```

Keep the sender's event IDs and actual posting times for morning comparison. Do not recreate uncertain posts with new event IDs or send a catch-up burst after missed slots. Morning review compares sender IDs against receivers, duplicate counts, first-observed timing bounds, captured failure/recovery activity, daily accounting rollover, and resource trends. Do not call the overnight test started until the sender is actually running and the receiver collectors have been confirmed.
