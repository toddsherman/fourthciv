# Fourth Civ: free pilot plan

Updated September 24, 2026. Status: Todd approved keeping Neon Free while minimizing existing Vercel costs. Local relay and protected-preview checks passed; staged production rollout is in progress.

## Decision and scope

Keep Neon on its free plan for a pilot used only by Todd's test Macs. Start with a small server-side caching change that preserves the installed apps' normal messaging cadence. Reassess when outside participants arrive or measured usage approaches the budget.

The existing Vercel team is **Pro**, and the relay runs in **iad1**. The original plan assumed no additional pilot charges on that subscription. Billing preflight disproved that assumption: the current-period usage report attributes approximately **$1.10** of billed usage to the relay, including approximately **$0.79** of Observability events. This is an in-progress usage report, not a final invoice. Vercel defines `billedCost` as the final charged amount in the usage report; do not subtract the plan credit again. CDN hits reduce origin work but still have infrastructure and monitoring costs. [Vercel usage reporting](https://vercel.com/docs/cli/usage), [tracked Observability events](https://vercel.com/docs/observability#tracked-events)

Neon's integration still reports the **Free** plan. No paid service or upgrade is part of this change. On September 24 Todd chose to keep Neon Free, accepting the approach of minimizing existing Vercel costs. An exactly zero hosting-usage ceiling is not the rollout requirement; this design does not guarantee one. Do not change team-wide billing or pause other sites to enforce this pilot's budget. Paid Observability is enabled at team level; apply and verify a relay-only exclusion as part of cost minimization, preserving every other project setting.

Working envelope: up to four test Macs, mostly quiet, occasional deliberate message tests, current public signed-event protocol. No scheduled message generator is needed for routine validation. Continuous automated posting is outside the quiet-pilot budget model.

## Why the allowance ran out

The installed app polls discovery and the event tail every approximately 60 seconds when quiet, or 30 seconds after activity. Each request currently reaches PostgreSQL for request admission and a read. This prevents the five-minute idle period Neon needs to suspend compute.

Neon's free allowance is 100 CU-hours per project per billing period. At 0.25 CU, continuous operation uses 180 CU-hours in 30 days. This is an illustrative calculation; the actual compute size, other active branches, usage, and reset date still need to be verified. [Neon free-plan limits](https://github.com/neondatabase/website/blob/main/content/faqs/free-plan-limits-and-quotas.md)

Source: `Sources/FourthCivCore/Node.swift` (`syncRelays`), `relay/lib/handler.mjs`, `relay/lib/store.mjs`, and `relay/schema.sql` (`fc_permit_request`).

## 1. Contain usage while preparing the change

- Between deliberate tests, pause internet participation on **all** test Macs. One still polling can keep the database active. This is an interim operator step, not something this plan has changed remotely.
- Check the Neon console/control-plane metrics for current usage, compute sizing, active branches, suspension status, and the exact reset date. Avoid recurring SQL health probes: they would keep waking the database.
- Retain the current database, epoch, signed events, and local Mac histories. If the quota is exhausted, use local/LAN tests and the existing separate development environment while waiting for the reset. Do not create replacement projects to cycle through free allowances.
- Code changes cannot restore consumed quota. Before a later deployment, snapshot the existing event IDs and epoch through the established operator process.

## 2. Make quiet checks inexpensive

Implement the first version in the relay only. Keep the existing native polling interval unless the compatibility check below shows a client change is necessary.

| Area | Proposed change |
| --- | --- |
| Public reads | Cache successful GET responses for discovery, events, communities, and public health at Vercel's CDN. Start with a 60-minute TTL and one relay tag scoped to the deployment environment. |
| Client caching | Use Vercel-specific cache headers; retain `Cache-Control: no-store` for clients so local HTTP caching does not hide newly published data. Source inspection found no native request headers that demand CDN bypass; verify this with the installed app. |
| Publishing | Validate the signature and envelope, commit the event in PostgreSQL, wait five seconds for older reads, then delete the relay's cache tag before reporting success. Cacheable origin reads have a four-second deadline, checked again after serialization with a monotonic clock. Delete on `already-present` retries too. |
| Cache failure after commit | Attempt bounded server-side purge retries, then return a retryable error. Repeated submissions can repair visibility without duplicating the event. Do not depend on them: a later GET can acknowledge the event and stop that Mac's POST retries. Finite cache expiry is the fallback repair; emit a redacted operational error. |
| Errors and private state | Never put POST responses, 429/503 errors, or source-specific admission information into shared cache. |
| Request validation | Reject unsupported paths, methods, duplicate/unknown query parameters, and invalid offsets before database access. Use canonical cacheable URLs; verify the Vercel rewrite does not defeat caching or fragment keys unexpectedly. |
| Request limits | CDN hits naturally bypass the handler and its PostgreSQL counters. Keep current durable limits for origin requests and publication; update discovery/docs to describe their new scope accurately. Check existing platform protections and use an included platform read-rate rule if needed and within budget. |
| Health and diagnostics | A cached health response shows a historical snapshot, not current write availability. Expose a safe snapshot timestamp and record sampled cache/origin counts and failures without message bodies, credentials, or raw client addresses. |

Vercel offers CDN response caching and tag purging on all plans. Use **tag deletion** after publication; marking a tag stale can serve an old response while refreshing. Purge calls themselves have no fee, but refills still consume infrastructure resources. [CDN caching](https://vercel.com/docs/caching/cdn-cache), [purging behavior](https://vercel.com/docs/caching/cdn-cache/purge)

Keep the adapter injectable so local tests can simulate cache failures. Expected code changes: `relay/lib/handler.mjs`, `relay/api/index.mjs`, a small cache adapter, relay tests/dependency lockfile, and operational documentation. Keep signature verification, atomic inserts, reference checks, event ordering, byte limits, and durable duplicate detection intact. Bound total database and purge attempts within the relay's 15-second duration and native request timeout; include lost-response recovery. Do not claim per-instance memory counters replace shared limits. Reject noncanonical offset spellings without redirecting canonical Mac requests; the native client rejects redirects.

Preview testing reproduced a late-fill race: a read started before commit could finish after immediate deletion, repopulate the CDN, and hide the new event. Early `addCacheTag` registration did not prevent it. The candidate therefore drains bounded reads before deletion. This adds about five seconds to a healthy publication acknowledgement and includes a one-second margin for provider/cache-ingress transport. Vercel does not document a bound on that transport; this is a tested pilot mitigation, not a guarantee of strict consistency under arbitrary provider delays. The total publication deadline is twelve seconds, including the drain and a subsequent three-second purge budget. Slow or cancelled attempts return an uncached 503; a committed event is retained.

CDN caches are regional and can miss. Independent cold regions, offsets, evictions, new deployments, and posts can still wake Neon. This design must pass measured usage gates; it is not a hard compute cap. If misses remain too frequent, evaluate a shared regional cache only after confirming its metered usage fits the budget. Runtime Cache is metered and must not be assumed free merely because it is available. [Runtime Cache](https://vercel.com/docs/caching/runtime-cache), [regional pricing](https://vercel.com/docs/pricing/regional-pricing)

## 3. Prove correctness and the cost reduction

Implement and test against the separate development/preview database first. Use synthetic events there. Production public posts are deliberate, persistent test actions, not automatic health checks.

Required checks:

1. Existing signatures, pagination, duplicate handling, durable local posts, and outage recovery continue to pass. Exercise current installed-app behavior, including native request cache policy.
2. Warm CDN reads invoke neither the relay function nor PostgreSQL. Verify this on the deployed platform for discovery, event pages including empty tails, communities, and health, not just with a mocked cache.
3. A new accepted post replaces an already-cached empty tail and reaches each awake receiver within two normal polling cycles (target: two minutes). Verify once from another network.
4. A committed post followed by cache-deletion failure or a lost response retries safely and becomes visible exactly once. Include the case where a later GET acknowledges the event and stops POST retries; another stale page must still recover. No success acknowledgement is fabricated when the database is unavailable.
5. Concurrent GET/POST and concurrent publications do not refill caches with indefinitely stale data. Test a GET started before commit that finishes after tag deletion, old/new epoch combinations, deployment changes, and recovery after cache failure on deployed Vercel. Healthy concurrent writes must meet the normal delivery target; otherwise fix the design before rollout. With purge failure, a stale response can persist up to the finite TTL (initially one hour), plus a polling cycle, if the database is available to refresh. Document that degraded delivery limit; do not present it as normal operation.
6. Cache entries never cross preview/production, cache an error, change signed envelopes, skip pagination, or obscure an epoch reset. Test replay/re-seeding with retained local events in the disposable environment.
7. Request protection remains effective and accurately described. Cover cache-key fragmentation, invalid inputs before SQL, unrelated source allowances, and platform-generated 429 behavior. Do not assume a browser challenge is usable by the Mac client.
8. After deployment, run a **24-hour quiet observation** with the test Macs awake, then one representative active session. Confirm Neon actually suspends between refreshes. Read usage through the provider's control plane; avoid a monitor that keeps issuing SQL.

Before promotion, pass the relevant checks in `docs/RELAY_HARDENING_ROLLOUT.md`, preserve the production epoch/history, and retain the prior deployment for rollback. A Mac release is needed only if native compatibility requires it.

## 4. Budget and acceptance criteria

| Measure | Pilot target / action |
| --- | --- |
| Neon compute | Projected **at most 50 CU-hours per full billing period**, including representative test activity. Recalculate from measured daily growth and actual period length. |
| Quiet behavior | Provider metrics show repeated suspended periods while all test Macs remain awake. A lower SQL count alone is insufficient. |
| Vercel | Keep Neon Free and minimize existing Vercel costs; measure requests, function usage, transfer, and monitoring against that agreed scope. No new paid dependency or subscription. |
| Data and delivery | Existing event IDs/epoch preserved; accepted posts propagate exactly once; pending local posts survive failures. |
| Other Neon quotas | Track actual database storage and transfer as well as compute. Serialized event bytes do not include indexes or counter-table storage. |

For perspective, four quiet Macs generate about **345,600 HTTP requests in 30 days** before posts, pagination, and manual checks; four continuously active Macs would generate about 691,200. Caching still consumes edge requests and bandwidth, so fewer database queries do not by themselves prove a $0 result.

An idealized single shared refresh each hour, followed by five active minutes at 0.25 CU, would consume about **15 CU-hours in 30 days**. This excludes extra cache keys/regions, writes, startup/refresh duration, maintenance, and evictions. It illustrates possible savings and is not a prediction of this deployment.

Once deployed, assess the 24-hour idle sample and representative active session, then validate the projection over seven days. These are planned validation steps; this document does not start a scheduled monitor or overnight sender.

## 5. When to reconsider

- Reassess before inviting the first outside participant, or whenever the test fleet or posting pattern materially changes.
- Investigate if projected Neon compute exceeds 50 CU-hours or remaining Vercel headroom becomes insufficient.
- At 75 CU-hours actually consumed in a period, suspend unnecessary background testing and review the remaining budget before continuing. This is a proposed operator threshold, not an installed automatic safeguard.
- If cached reads cannot meet the budget reliably, use deliberate test sessions with all other participants paused. A future economy mode could coordinate sync windows, but it adds client work and delivery delay; it is not the first implementation.
- If sustained real usage develops, compare the measured cost of paid Neon against an alternative relay backend. No automatic paid upgrade is part of this plan.

The operational commitment is to stay on the free database plan and validate usage early. With a hard $0 ceiling, temporary pilot unavailability is preferable to an unapproved paid upgrade. Unlimited public use at $0 is not promised.

If rollback is needed, preserve all newly accepted events and the epoch; restore code only. The old implementation resumes continuous database activity, so pair rollback with pausing nonessential test Macs.

## Implementation order

1. Verify billing headroom, Neon configuration/reset date, and native cache compatibility.
2. Implement the relay caching/purge path, truthful limit/health reporting, and redacted diagnostics.
3. Verify locally and in isolated preview, including cache races and failure recovery.
4. Deploy through the existing reviewed rollout procedure; compare retained production history.
5. Measure the quiet day and active session, then a seven-day projection; revisit before outside use.

## Preflight evidence and remaining gates

- Production baseline contains 39 signature-verified events, epoch `d76e247f-68d8-4c82-a058-0f2aea345f7d`. A restricted local backup was retained before candidate work. No production test events have been posted.
- Protected previews use the separate development database. CDN tests proved repeat HITs with unchanged origin timestamps, post-commit invalidation, signed-event deduplication, and uncached invalid requests. The stronger delayed-reader test exposed the race described above; the revised candidate passed reads below/above its deadline and concurrent writers. A final uninstrumented preview passed the full CDN round trip. See [validation](VALIDATION.md) for deployment IDs and evidence.
- All 41 relay tests, the native Swift CLI build, signed-event interop and outage recovery passed. A full native test rerun was blocked before execution by local SwiftUI macro loading in unchanged app code. Native-to-public-CDN verification, another-network delivery, production history comparison, and the quiet-day measurements remain rollout gates.
- The Neon console requires interactive authentication. Actual compute size, current CU-hours, suspended periods, and Neon reset date remain unverified. The Vercel billing-period reset is not the Neon reset date. No database-polling monitor or overnight sender has been started.
- Evidence is retained under `.local/free-pilot-cache-20260923/private/`; it is intentionally not published with the source. The public validation record will summarize completed checks without credentials or participant data.
