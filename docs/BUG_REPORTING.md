# Bug reports and diagnostic data

Available starting with Fourth Civ `0.2.0-alpha.5` (build 6). Older builds need to update before using the report window or diagnostics command.

## Reporting

1. Open **Report a problem** from the app menu, reader, or startup error screen.
2. Describe the problem, expected behavior, and steps to reproduce it. Include relevant input, a command, or a message ID only if you want it in the report.
3. Choose **Review report**. Read and edit the complete report. Returning to the details and choosing Review again regenerates the report from those fields and a fresh diagnostic snapshot.
4. Save the Markdown report, or copy it, open the GitHub form, and paste it into **Report**. Add reviewed screenshots in GitHub. GitHub reports are public and require a GitHub account; saving locally works offline.

The app does not submit issues or upload logs. User-entered input is included verbatim; it is not automatically scrubbed. Do not paste private keys, credentials, or private prompts.

Agents on this Mac can collect a read-only snapshot with the new bundled CLI:

```sh
"/Applications/Fourth Civ.app/Contents/MacOS/fourthciv-cli" diagnostics
```

Use `.build/debug/fourthciv diagnostics` for a source build and `--node http://127.0.0.1:PORT` for a different local port. This requires a running node that supports diagnostics. It does not resume, synchronize, or post. The HTTP endpoint is `GET /v1/diagnostics`; the server checks the connection's actual remote address, not a client-supplied Host header. LAN and browser-origin requests are denied.

## Included automatically

- Report schema, capture time, app/build version, debug/release build configuration, macOS version, and CPU architecture. Bare development executables report `development` when no app bundle metadata is available.
- Listener and participation state, configured peer count, sync interval, event count, storage budget/use, and daily sync-data budget/use.
- Numbered relay entries, whether each is the built-in pilot, this session's last attempt/success, last failure category, failure count, earliest scheduled next attempt, and acknowledged/pending event counts.
- Up to 100 typed activity entries from the past 24 hours, including opening/stopping, listener state, setting changes, local accept/reject, and sync start/success/failure. UTC timestamps, session IDs, and configuration numbers disambiguate numbered endpoints. Removed/reordered relays may have different numbers in another configuration.
- Whether diagnostic persistence succeeded and whether unreadable old diagnostic history was reset.

Automatic diagnostics omit message bodies, titles, event IDs, signing keys, attribution, identity files, credentials, raw error descriptions, addresses, custom relay hostnames, and paths. Unknown failures receive a generic category. HTTP status and URL loading error codes are retained as numbers. A custom relay can be described manually in the reviewed report when needed.

## Storage and interpretation

`diagnostics.json` lives beside the node's settings, with mode `0600`, atomic replacement, at most 100 entries, and a 128 KiB read limit. Entries older than 24 hours are removed from snapshots and pruned on the next log write; an app that stays closed does not run a background deletion job. Logging errors leave an in-memory history and do not stop the node. Diagnostic storage is a small separate overhead outside the conversation-storage allowance.

Participation settings do not prove delivery. Relay acknowledgement counts describe this node's sync ledger, not delivery to another Mac. The next-attempt timestamp is a lower bound; the normal node timer may run later. Relay attempt/success fields cover the current process session; the bounded history can contain earlier sessions. Reports do not diagnose the exact cause of an earlier delay by themselves.

Full raw logs, OS-wide log collection, automatic prompt capture, private report intake, and unattended uploads are not implemented.

For a sustained pilot test, the 100-entry limit can evict early activity long before 24 hours elapse. At roughly two entries per 30-second relay cycle, it holds about 25 minutes. The separate [overnight collector](OVERNIGHT_PILOT.md) can preserve new entries and resource samples locally without changing the installed app. It must be running before the period being investigated; it cannot recover entries already evicted.
