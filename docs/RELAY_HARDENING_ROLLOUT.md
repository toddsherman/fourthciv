# Relay hardening rollout

This checklist prepares and verifies the request-isolation candidate. It is not a record of a completed deployment. The native idle-polling change needs a separately signed Mac release; existing alpha.10/alpha.11 clients remain compatible with the relay change.

## Candidate gates

- Record the exact clean source commit. Run the native/integration suite, relay tests, Swift interop, outage recovery, release-signature checks, website build, and production dependency audits.
- Read [the security findings](SECURITY_REVIEW.md), including shared-NAT limits, denied-request infrastructure cost, and unresolved spam/history capacity. The eight-host test is a deterministic database admission exercise, not a live Neon load test.
- Keep the previous relay deployment available for rollback. No app or relay event history should be deleted for this rollout.

## Isolated preview

1. Confirm preview/development point to the separate development database, never production. Keep preview deployment protection enabled. Use only synthetic events there.
2. Set a dedicated sensitive `FOURTHCIV_REQUEST_KEY` (64 random hex characters) for preview. Do not display or commit it. Apply `relay/schema.sql` through `npm run migrate`. The migration adds request tables/functions and preserves event IDs, counters, and epoch; existing publication limits remain unchanged.
3. Deploy the exact candidate to a preview of the relay project. Verify discovery/health and signed event round-trip with the existing CLI through the authorized preview access path. A protected preview may require an operator-only harness that supplies the platform bypass header; never disable native TLS verification or publish the bypass token.
4. Verify Vercel supplies trusted source metadata: make one normal read and one read with forged `x-forwarded-for`, `x-real-ip`, and `x-vercel-forwarded-for` values. From operator-side database assertions, confirm the two requests increment the same pseudonymous client counter. Do not return raw addresses, digests, secrets, or diagnostic endpoints publicly. The shared handler's local tests cannot prove platform header replacement.
5. Exercise HTTP 429/minute recovery on the isolated preview, using a test clock at the database layer or deliberately seeded test counters. Verify another independent source remains admitted. Do not flood the public relay. Real simultaneous transactions from separate database connections should preserve both source and global limits.
6. Confirm malformed requests, missing configuration, signed event deduplication, and stored history behave as documented. Clear synthetic test data only within the explicitly disposable preview environment.

## Production promotion

1. Before changing production, snapshot its epoch, event count, event IDs and signed envelopes through an access-controlled operator path. Retain the previous deployment and a database backup. Keep credentials and host identifiers out of reports.
2. Provision the independent production request key and apply the additive schema. The previous handler keeps working during this step because its old request counters/functions remain present. New admission counters start empty once; do not repeatedly recreate or clear them.
3. Promote the exact verified relay candidate. Confirm health and discovery advertise the new limits, existing history/epoch is unchanged, and installed alpha.11 hosts still synchronize. Prefer existing signed events for read-only production validation; new public test posts require an intentional operator decision because they persist.
4. Record the deployment ID, source commit, time, checks, and any faults in `VALIDATION.md`. Monitor existing host diagnostics and operator-side counters during the first day; this document does not create a scheduled monitor.
5. If validation fails, restore the previous deployment while preserving events and epoch. Leave the additive tables/key in place until a reviewed cleanup; do not restore an old event snapshot over newer public messages. The old quota weakness returns during rollback and must be recorded.

Publish a new Mac build only after its own signing, notarization, download, update, and installed-app checks. The friend checklist is in [PILOT_HOST_GUIDE.md](PILOT_HOST_GUIDE.md).
