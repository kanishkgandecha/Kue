-- Kue 3.0 Phase 5 production repair.
--
-- Row Level Security decides which rows an authenticated user may access, but PostgreSQL
-- table privileges are evaluated first. The original profile/sync migrations created RLS
-- policies without granting the authenticated role the corresponding table operations,
-- causing PostgREST requests to fail with HTTP 403 before RLS could evaluate them.

grant usage on schema public to authenticated;

-- Profile rows are created by the auth-user trigger and deleted by the account-deletion
-- service. App clients only need to read and edit their own row.
grant select, update on table public.profiles to authenticated;

-- Sync deletion is represented by tombstones/updates, so clients need no direct DELETE.
grant select, insert, update on table
  public.sync_events,
  public.sync_tasks,
  public.sync_schedules,
  public.sync_recurrence_exclusions,
  public.sync_notification_rules
to authenticated;

-- The sync trigger and defaults allocate monotonically increasing server revisions.
grant usage, select on sequence public.kue_sync_seq to authenticated;
