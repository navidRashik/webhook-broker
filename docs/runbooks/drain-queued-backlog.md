# Runbook: Drain a stuck QUEUED backlog for a pull consumer

## When to use this

A pull consumer's `GET /channel/{channel}/consumer/{consumer}/queued-jobs` request
times out (HTTP 504 at ~60s), the consumer cannot fetch, its QUEUED backlog keeps
growing, and it never recovers on its own (death spiral).

Root cause and the permanent fix (composite index + `consumerId = ?`) are covered in
migration `000013_add_prioritized_jobs_index` and `storage/deliveryjobrepo.go`. **Apply
the code fix first** — it prevents recurrence. This runbook clears the *already
accumulated* backlog so the consumer can recover, because there is no HTTP endpoint that
purges QUEUED jobs.

> **Status integers (verify before running anything):** QUEUED=**1001**, INFLIGHT=1002,
> DELIVERED=1003, DEAD=1004. Defined in `storage/data/job.go` (`iota + 1000`, with
> `deliverJobLockPrefix` consuming iota=0). **QUEUED is 1001, not 1000.** Using 1000
> matches nothing.

## Preconditions & scope

- **Both deployments.** There are two independent brokers (AWS and GCP) with their own
  MySQL databases and the same channel/consumer names. Perform the drain **on each**.
- **Dropping stale QUEUED jobs is acceptable** for the affected consumer: the downstream
  consumer backfills missed events out-of-band. Confirm this is still true for the
  specific consumer before deleting.
- This is a **DBA / maintainer action on shared production**. Take a snapshot/backup or
  ensure PITR is available first. Do not run destructive statements without sign-off.

## Part A — Zero-downtime index rollout (do this before/with the code deploy)

Migrations run **synchronously at app startup** under a lock (`storage/rdbms.go`), so a
blocking `CREATE INDEX` on the large `job` table could stall pod startup / trip the
startupProbe. Migration 000013 is therefore **idempotent** (creates only if absent).

Recommended sequence per database:

1. **Build the index out-of-band first** (online, non-blocking). Preferred, replication-safe:
   ```bash
   gh-ost \
     --host=<primary> --database=webhook-broker --table=job \
     --alter="ADD INDEX \`job_consumer_status_priority\` (\`consumerId\`, \`status\`, \`priority\` DESC, \`createdAt\` DESC, \`id\` DESC)" \
     --allow-on-master --max-lag-millis=1500 --exact-rowcount --execute
   ```
   Or, if `gh-ost`/`pt-online-schema-change` is not available and traffic tolerates it:
   ```sql
   CREATE INDEX `job_consumer_status_priority`
     ON `job` (`consumerId`, `status`, `priority` DESC, `createdAt` DESC, `id` DESC)
     ALGORITHM=INPLACE LOCK=NONE;
   ```
   `LOCK=NONE` keeps reads/writes flowing during the build; expect extra IO/CPU and some
   replica lag on a large table — run during a low-traffic window and watch lag.

2. **Deploy the code.** At startup, migration 000013 sees the index already exists and is
   an instant no-op — no blocking DDL, no held lock.

3. Verify the index exists:
   ```sql
   SELECT index_name FROM information_schema.statistics
   WHERE table_schema = DATABASE() AND table_name = 'job'
     AND index_name = 'job_consumer_status_priority';
   ```

> If the index is *not* pre-built, the in-band fallback still runs the **online**
> `ALGORITHM=INPLACE, LOCK=NONE` create (never a blocking rebuild) and is safe to re-run —
> but it will hold the migration during the build, so pre-building is strongly preferred on
> the large prod table.

## Part B — Drain the existing QUEUED backlog (primary method: scoped batched DELETE)

Run on **each** database (AWS and GCP).

### B1. Resolve the internal consumer id

The `job.consumerId` column stores the consumer's **internal `consumer.id`** (a xid), not
the human-facing `consumerId`/name. Resolve it by the public consumer id + channel:

```sql
SELECT c.id AS internal_consumer_id, c.consumerId, c.channelId, c.name
FROM consumer c
WHERE c.consumerId = '<public-consumer-id>'   -- e.g. shamwow-asset-modified-consumer
  AND c.channelId  = '<channel-id>';          -- e.g. eb_cmp_asset_modified
```

Record `internal_consumer_id`. All statements below use it.

### B2. Confirm the backlog size (read-only)

```sql
SELECT COUNT(*) AS queued_count
FROM job
WHERE consumerId = '<internal_consumer_id>' AND status = 1001;  -- 1001 = QUEUED
```

Sanity-check the number matches the observed backlog before deleting.

### B3. Batched delete (avoid long locks / replication lag)

Delete in bounded batches rather than one large transaction. Loop until 0 rows affected:

```sql
-- Repeat until "Rows matched: 0". Pause briefly between batches; watch replica lag.
DELETE FROM job
WHERE consumerId = '<internal_consumer_id>' AND status = 1001
LIMIT 5000;
```

Example shell loop (MySQL CLI):
```bash
INTERNAL_ID='<internal_consumer_id>'
while :; do
  n=$(mysql -N -B webhook-broker -e \
    "DELETE FROM job WHERE consumerId='$INTERNAL_ID' AND status=1001 LIMIT 5000; SELECT ROW_COUNT();")
  echo "deleted batch: $n"
  [ "$n" -eq 0 ] && break
  sleep 1   # let replicas catch up
done
```

> **Scope tightly.** Always include both `consumerId = '<internal_consumer_id>'` **and**
> `status = 1001`. Never delete by status alone or across consumers. Only QUEUED (1001) is
> removed — INFLIGHT/DELIVERED/DEAD jobs are untouched.

### B4. Verify drained

```sql
SELECT COUNT(*) FROM job
WHERE consumerId = '<internal_consumer_id>' AND status = 1001;   -- expect 0
```

Then confirm the consumer's `queued-jobs` endpoint returns quickly (well under 60s) and the
consumer resumes fetching.

### B5. Repeat on the other deployment

Perform B1–B4 on the second broker's database (the AWS and GCP hosts are independent).

## Alternatives (not recommended as primary)

- **Reclassify QUEUED → DEAD then purge via DLQ endpoint.**
  `UPDATE job SET status = 1004, statusChangedAt = NOW() WHERE consumerId = '<id>' AND status = 1001;`
  then `DELETE /channel/{channel}/consumer/{consumer}/dlq`. Uses a sanctioned API path but
  touches more rows/state and updates DLQ summary counters; slower and higher blast radius.
  Only consider if a pure DELETE is disallowed by policy.

## Post-drain checklist

- [ ] Index `job_consumer_status_priority` present on **both** DBs.
- [ ] Code fix deployed (migration 000013 + `consumerId = ?` query) on both brokers.
- [ ] QUEUED count for the affected consumer == 0 on both DBs.
- [ ] `queued-jobs` latency back to milliseconds; consumer fetching normally.
- [ ] Backfill of any dropped events kicked off on the consumer side (out-of-band).
