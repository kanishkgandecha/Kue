-- Kue 3.0 Phase 6 — docs/34-kue-3-cloud-profile-and-productivity-statistics.md "Supabase
-- aggregate storage." Forward-only, applied AFTER Phase 5's own migration
-- (20260912000000_create_sync_tables.sql) — does not touch, alter, or depend on any table
-- that migration created.
--
-- One table, `statistics_aggregates`: a deliberately narrow set of already-aggregated numbers
-- (never event/task titles, notes, locations, OCR/voice content, Calendar identifiers, or
-- event/task UUIDs — requirement A) computed entirely on-device by
-- `Shared/Services/Accounts/ProfileStatisticsEngine.swift` and derived into the upload shape
-- by `StatisticsAggregatePayload.make(from:)` (Shared/Services/Statistics/). Cloud statistics
-- are strictly opt-in (`CloudStatisticsPreference`, default off) and this table's own RLS
-- policies are the enforcement boundary, not the client's good behavior alone.
--
-- Bucketing: one row per account per ISO calendar week (`bucket_start`, that week's Monday, a
-- bare `date` — no time-of-day, no time zone, the smallest useful grain given requirement D's
-- "prefer daily or weekly aggregate buckets over uploading raw event/task history"). Each row
-- is a **snapshot** of the account's cumulative statistics as of the most recent upload that
-- landed in that week — re-uploading within the same week overwrites that week's row via a
-- plain PostgREST upsert (`on_conflict=user_id,bucket_start`, `Prefer: resolution=merge-
-- duplicates`) against this table's own primary key; there is no server-side function or RPC
-- needed for idempotency here; unlike Phase 5's event-graph push, an aggregate overwrite is
-- always sound; it is a full replacement of a small, non-conflicting summary, never a partial
-- merge two devices could each hold a different "correct" half of.

-- ============================================================================================
-- 1. statistics_aggregates
-- ============================================================================================

create table if not exists public.statistics_aggregates (
  user_id uuid not null references auth.users (id) on delete cascade,
  bucket_start date not null,
  total_active_events integer not null default 0 check (total_active_events >= 0),
  completed_events integer not null default 0 check (completed_events >= 0),
  cancelled_events integer not null default 0 check (cancelled_events >= 0),
  skipped_events integer not null default 0 check (skipped_events >= 0),
  events_needing_review integer not null default 0 check (events_needing_review >= 0),
  completed_tasks integer not null default 0 check (completed_tasks >= 0),
  pending_tasks integer not null default 0 check (pending_tasks >= 0),
  -- A fraction in [0, 1], never a raw percentage integer — `null` means "not enough task data
  -- yet" (`ProfileStatistics.completionRate`'s own honest-zero-denominator contract), never a
  -- stand-in `0`.
  task_completion_rate numeric(5, 4) check (task_completion_rate is null or (task_completion_rate >= 0 and task_completion_rate <= 1)),
  upcoming_7_days integer not null default 0 check (upcoming_7_days >= 0),
  upcoming_30_days integer not null default 0 check (upcoming_30_days >= 0),
  preparation_workload integer not null default 0 check (preparation_workload >= 0),
  current_streak integer check (current_streak is null or current_streak >= 0),
  longest_streak integer check (longest_streak is null or longest_streak >= 0),
  -- Hours; genuinely allowed to be negative (tasks completed after their own due date on
  -- average) — never clamped to hide that. `null` below the engine's own minimum-sample
  -- threshold.
  avg_task_completion_lead_time_hours numeric(10, 2),
  -- `longest_streak` can never be smaller than `current_streak` — both are computed from the
  -- exact same resolved-history scan (`ProfileStatisticsEngine.completionStreaks`'s own
  -- header); a row where that isn't true could only come from a malformed/tampered payload.
  constraint statistics_aggregates_streak_order check (
    longest_streak is null or current_streak is null or longest_streak >= current_streak
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, bucket_start)
);

create index if not exists statistics_aggregates_user_bucket_idx on public.statistics_aggregates (user_id, bucket_start desc);

drop trigger if exists statistics_aggregates_set_updated_at on public.statistics_aggregates;
create trigger statistics_aggregates_set_updated_at
  before update on public.statistics_aggregates
  -- Reuses Phase 4's own generic `set_updated_at()` (supabase/migrations/
  -- 20260911000000_create_profiles.sql) rather than a second, duplicate trigger function.
  for each row execute function public.set_updated_at();

comment on table public.statistics_aggregates is
  'Kue 3.0 Phase 6 — one row per account per ISO week, deliberately-selected aggregate counts only. See docs/34.';

-- ============================================================================================
-- 2. Row Level Security — owner-only, every verb, no anonymous access anywhere
-- ============================================================================================

alter table public.statistics_aggregates enable row level security;

drop policy if exists "select own rows" on public.statistics_aggregates;
create policy "select own rows" on public.statistics_aggregates
  for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "insert own rows" on public.statistics_aggregates;
create policy "insert own rows" on public.statistics_aggregates
  for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "update own rows" on public.statistics_aggregates;
create policy "update own rows" on public.statistics_aggregates
  for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Unlike every Phase 5 sync table, a real DELETE policy is appropriate here: an aggregate row
-- carries no tombstone/offline-conflict semantics another device needs to reconcile against —
-- "Delete Cloud Statistics" (requirement F) is a genuine, immediate, permanent removal of the
-- caller's own previously-uploaded numbers, never a soft-delete.
drop policy if exists "delete own rows" on public.statistics_aggregates;
create policy "delete own rows" on public.statistics_aggregates
  for delete to authenticated
  using (auth.uid() = user_id);

-- Supabase's API roles still require table privileges in addition to passing RLS. Keep anon
-- structurally unable to query this private data, while authenticated callers remain constrained
-- by the owner-only policies above.
revoke all on table public.statistics_aggregates from public, anon;
grant select, insert, update, delete on table public.statistics_aggregates to authenticated;

-- ============================================================================================
-- 3. Account-scoped cleanup — mirrors Phase 4/5's own reliance on `on delete cascade`: deleting
--    the `auth.users` row removes every one of that account's aggregate rows automatically. No
--    separate cleanup function is needed or added.
-- ============================================================================================
