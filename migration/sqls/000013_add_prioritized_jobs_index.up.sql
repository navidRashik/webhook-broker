-- Add composite index backing the pull-consumer queued-jobs query:
--   SELECT ... FROM job WHERE consumerId = ? AND status = ?
--   ORDER BY priority DESC, createdAt DESC, id DESC LIMIT ?
-- Column order matches WHERE-equality columns first, then the ORDER BY columns in
-- order/direction, so the DB satisfies both the filter and the sort from the index
-- (no filesort) and LIMIT can terminate early. Without it the query filesorts the
-- consumer's entire QUEUED backlog -> O(backlog) latency -> 504 for busy consumers.
--
-- This migration is idempotent so it can be a no-op at app startup when the index has
-- already been built out-of-band (gh-ost / pt-online-schema-change / ALGORITHM=INPLACE,
-- LOCK=NONE). See docs/runbooks/drain-queued-backlog.md for the zero-downtime rollout.

{{if eq .Dialect "mysql"}}
-- Create only if missing; build online (non-blocking) when it must run in-band.
SET @idx_exists := (
    SELECT COUNT(1) FROM information_schema.statistics
    WHERE table_schema = DATABASE() AND table_name = 'job'
      AND index_name = 'job_consumer_status_priority'
);
SET @ddl := IF(@idx_exists = 0,
    'CREATE INDEX `job_consumer_status_priority` ON `job` (`consumerId`, `status`, `priority` DESC, `createdAt` DESC, `id` DESC) ALGORITHM=INPLACE LOCK=NONE',
    'DO 0');
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
{{else}}
CREATE INDEX IF NOT EXISTS `job_consumer_status_priority` ON `job` (`consumerId`, `status`, `priority` DESC, `createdAt` DESC, `id` DESC);
{{end}}

-- Generated with assistance from Claude AI
