-- Kue 3.0 Phase 5 — docs/33-kue-3-supabase-cross-device-sync.md "Schema and RLS."
--
-- Cross-device sync tables for the user-owned domain graph: events, tasks, schedules,
-- recurrence exclusions, and event/task-owned notification rules. Applied AFTER the Phase 4
-- migration (20260911000000_create_profiles.sql) — `user_id` here references `auth.users`
-- directly (not `profiles`), the same choice `profiles` itself would make if it had a parent,
-- so a row never depends on `handle_new_user()`'s trigger having already committed.
--
-- Normalized, one table per local model (`sync_events`/`sync_tasks`/`sync_schedules`/
-- `sync_recurrence_exclusions`/`sync_notification_rules`) rather than one JSON blob per event —
-- but the *push* API (section further down) still accepts and atomically applies one whole
-- "event graph" per call, matching the client's own `EventSyncRecord` shape (Kue 2.0 Phase 11)
-- and preserving that phase's core safety property: one malformed/rejected event graph can
-- never corrupt or silently drop an unrelated one in the same batch (requirement G).
--
-- Every synced model already has a stable, client-generated UUID `id` (Kue 3.0 Phase 5
-- preparation audit) — but that `id` is only unique *within one account*, never globally.
-- **Phase 5 correction**: an earlier draft of this migration made `id uuid primary key` the
-- whole key, which meant two different Supabase accounts could never independently use the
-- same client-generated UUID (a real, likely-to-happen collision — two devices that both
-- start numbering from a fresh local database, or two accounts sharing a device's local
-- store history, can easily mint the same value) without one account's row colliding with, or
-- disclosing the existence of, the other's. Every synced table's real primary key is now the
-- composite `(id, user_id)` — a UUID is only ever unique per owning account, exactly like
-- every other column here is already scoped — and every child table's foreign key to its
-- parent is the matching composite `(parent_id, user_id)`, which has the added benefit of
-- enforcing "a child row's parent belongs to the same account" as a schema-level constraint,
-- not merely an RLS `with check` (both are kept — see section 6 — for defense in depth).
--
-- Conflict authority is server-controlled, never a client clock: every table carries a
-- `revision` (monotonic per row, bumped only by this migration's own trigger) and a
-- `server_updated_at` (stamped by the same trigger) — a client's own `client_updated_at` is
-- carried through for display/debugging only and is never consulted for ordering.
--
-- No event/task/notification-rule *content* is ever logged by this migration or the functions
-- below — every error path returns a short, generic code, never event titles/notes/locations.

-- ============================================================================================
-- 0. Shared sequence and helper
-- ============================================================================================

-- One sequence shared by every synced table, so a client's pull cursor stays one number per
-- table rather than reasoning about six independently-restarting counters, and a page never
-- needs to break ties within a single (server_seq) value — sequences hand out values one at a
-- time, so `server_seq` is unique across the whole account's synced graph by construction.
create sequence if not exists public.kue_sync_seq;

-- Bumps revision/server_updated_at/server_seq on every write (insert or update) — the one
-- place these three columns are ever set; a client can send whatever it wants for them and
-- this trigger overwrites it unconditionally, so a client-supplied value is never trusted for
-- conflict ordering (requirement: "Do not trust client clocks as the conflict authority").
create or replace function public.touch_sync_revision()
returns trigger
language plpgsql
as $$
begin
  -- `OLD` is not a valid record to dereference during a plain INSERT (only `ON CONFLICT DO
  -- UPDATE`'s update path has a real one) — branch on `TG_OP` explicitly rather than relying
  -- on `coalesce(old.revision, 0)`, which is not guaranteed safe across Postgres versions when
  -- this same trigger function fires for both operations.
  if tg_op = 'INSERT' then
    new.revision := 1;
  else
    new.revision := old.revision + 1;
  end if;
  new.server_updated_at := now();
  new.server_seq := nextval('public.kue_sync_seq');
  return new;
end;
$$;

-- ============================================================================================
-- 1. sync_events — one row per local KueEvent, keyed per-account by (id, user_id)
-- ============================================================================================

create table if not exists public.sync_events (
  id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null,
  event_type text not null check (event_type in ('generic', 'deadline', 'exam', 'interview', 'trip')),
  start_date timestamptz not null,
  end_date timestamptz,
  estimated_duration_minutes integer not null default 0 check (estimated_duration_minutes >= 0),
  is_all_day boolean not null default false,
  time_zone_identifier text not null,
  location text,
  notes text,
  source text not null check (source in ('manual', 'naturalLanguage', 'shareSheet', 'calendarImport', 'ocr', 'voice', 'shortcuts')),
  priority text not null check (priority in ('low', 'medium', 'high')),
  is_cancelled boolean not null default false,
  cancelled_at timestamptz,
  is_manually_completed boolean not null default false,
  manually_completed_at timestamptz,
  -- RecurrenceRule, flattened (mirrors RecurrenceRulePayload — Shared/Services/Sync/EventSyncRecord.swift)
  recurrence_frequency text check (recurrence_frequency in ('daily', 'weekly', 'monthly', 'yearly')),
  recurrence_interval integer check (recurrence_interval is null or recurrence_interval >= 1),
  recurrence_end_kind text check (recurrence_end_kind in ('never', 'onDate', 'afterOccurrences')),
  recurrence_end_date timestamptz,
  recurrence_end_occurrence_count integer,
  series_id uuid,
  recurrence_anchor_date timestamptz,
  is_recurrence_exception boolean not null default false,
  is_skipped boolean not null default false,
  skipped_at timestamptz,
  created_at timestamptz not null,
  -- Client-reported "last edited" instant — display/debugging only, never the conflict
  -- authority (see `touch_sync_revision()` above and docs/33 "Conflict policy").
  client_updated_at timestamptz not null,
  -- The pushing client's own idempotency key for *this specific mutation* — a retried push of
  -- the same logical write carries the same value, letting `push_event_graph` recognize and
  -- return the original result untouched, rather than re-applying or bumping revision again
  -- (Phase 5 correction — see that function's own header for the full idempotency contract).
  client_mutation_id uuid not null,
  is_deleted boolean not null default false,
  deleted_at timestamptz,
  payload_version integer not null default 1,
  revision bigint not null default 1,
  server_updated_at timestamptz not null default now(),
  server_seq bigint not null default nextval('public.kue_sync_seq'),
  primary key (id, user_id)
);

create index if not exists sync_events_user_seq_idx on public.sync_events (user_id, server_seq);
create index if not exists sync_events_series_idx on public.sync_events (series_id) where series_id is not null;

drop trigger if exists sync_events_touch_revision on public.sync_events;
create trigger sync_events_touch_revision
  before insert or update on public.sync_events
  for each row execute function public.touch_sync_revision();

comment on table public.sync_events is
  'Kue 3.0 Phase 5 — one row per synced KueEvent, keyed per-account by (id, user_id). See docs/33-kue-3-supabase-cross-device-sync.md.';

-- ============================================================================================
-- 2. sync_tasks — one row per local KueTask, owned by exactly one sync_events row in the same
--    account (the composite foreign key enforces the "same account" half; the RLS `with check`
--    in section 6 enforces it again at write time — see this file's header for why both exist)
-- ============================================================================================

create table if not exists public.sync_tasks (
  id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  event_id uuid not null,
  title text not null,
  due_date timestamptz not null,
  is_completed boolean not null default false,
  completed_at timestamptz,
  offset_label text not null default '',
  sort_order integer not null default 0,
  created_at timestamptz not null,
  client_updated_at timestamptz not null,
  client_mutation_id uuid not null,
  is_deleted boolean not null default false,
  deleted_at timestamptz,
  payload_version integer not null default 1,
  revision bigint not null default 1,
  server_updated_at timestamptz not null default now(),
  server_seq bigint not null default nextval('public.kue_sync_seq'),
  primary key (id, user_id),
  foreign key (event_id, user_id) references public.sync_events (id, user_id) on delete cascade
);

create index if not exists sync_tasks_event_idx on public.sync_tasks (event_id, user_id);
create index if not exists sync_tasks_user_seq_idx on public.sync_tasks (user_id, server_seq);

drop trigger if exists sync_tasks_touch_revision on public.sync_tasks;
create trigger sync_tasks_touch_revision
  before insert or update on public.sync_tasks
  for each row execute function public.touch_sync_revision();

-- ============================================================================================
-- 3. sync_schedules — one row per local KueSchedule, owned 1:1 by a sync_events row in the
--    same account
-- ============================================================================================

create table if not exists public.sync_schedules (
  id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  event_id uuid not null,
  template_type text not null check (template_type in ('generic', 'deadline', 'exam', 'interview', 'trip', 'custom')),
  -- [ScheduleRulePayload] — a small, bounded array; JSONB keeps this table from needing its
  -- own grandchild table for something with no independent identity of its own.
  rules jsonb not null default '[]'::jsonb,
  is_custom boolean not null default false,
  generated_at timestamptz not null,
  created_at timestamptz not null,
  client_updated_at timestamptz not null,
  client_mutation_id uuid not null,
  is_deleted boolean not null default false,
  deleted_at timestamptz,
  payload_version integer not null default 1,
  revision bigint not null default 1,
  server_updated_at timestamptz not null default now(),
  server_seq bigint not null default nextval('public.kue_sync_seq'),
  primary key (id, user_id),
  unique (event_id, user_id),
  foreign key (event_id, user_id) references public.sync_events (id, user_id) on delete cascade
);

create index if not exists sync_schedules_user_seq_idx on public.sync_schedules (user_id, server_seq);

drop trigger if exists sync_schedules_touch_revision on public.sync_schedules;
create trigger sync_schedules_touch_revision
  before insert or update on public.sync_schedules
  for each row execute function public.touch_sync_revision();

-- ============================================================================================
-- 4. sync_recurrence_exclusions — create-only, immutable once made (mirrors the local
--    RecurrenceExclusion model and Kue 2.0 Phase 11's own CloudKit-era handling of it exactly)
-- ============================================================================================

create table if not exists public.sync_recurrence_exclusions (
  id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  series_id uuid not null,
  excluded_anchor_date timestamptz not null,
  client_mutation_id uuid not null,
  is_deleted boolean not null default false,
  deleted_at timestamptz,
  payload_version integer not null default 1,
  revision bigint not null default 1,
  server_updated_at timestamptz not null default now(),
  server_seq bigint not null default nextval('public.kue_sync_seq'),
  primary key (id, user_id),
  unique (user_id, series_id, excluded_anchor_date)
);

create index if not exists sync_recurrence_exclusions_user_seq_idx on public.sync_recurrence_exclusions (user_id, server_seq);

drop trigger if exists sync_recurrence_exclusions_touch_revision on public.sync_recurrence_exclusions;
create trigger sync_recurrence_exclusions_touch_revision
  before insert or update on public.sync_recurrence_exclusions
  for each row execute function public.touch_sync_revision();

-- ============================================================================================
-- 5. sync_notification_rules — one row per local NotificationRule, owned by exactly one of
--    sync_events OR sync_tasks in the same account (never both, never neither — mirrors the
--    local model's own `event: KueEvent? / task: KueTask?` "exactly one set" invariant,
--    `NotificationRuleValidator` enforces it locally, this CHECK enforces it here). Both
--    parent foreign keys are composite and both are nullable — a multi-column foreign key with
--    any null member column is automatically satisfied without a lookup (Postgres's default
--    `MATCH SIMPLE`), which is exactly what "exactly one of these two is ever set" needs.
-- ============================================================================================

create table if not exists public.sync_notification_rules (
  id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  event_id uuid,
  task_id uuid,
  constraint sync_notification_rules_exactly_one_owner check ((event_id is not null) <> (task_id is not null)),
  anchor text not null check (anchor in ('eventStart', 'eventEnd', 'outcomeFollowUp', 'taskDue', 'absolute')),
  offset_direction text not null check (offset_direction in ('before', 'at', 'after')),
  offset_quantity integer not null default 0,
  offset_unit text not null check (offset_unit in ('minutes', 'hours', 'days', 'weeks')),
  absolute_date timestamptz,
  is_enabled boolean not null default true,
  custom_title text,
  custom_body text,
  sound text not null default 'defaultSound' check (sound in ('defaultSound', 'silent')),
  interruption_preference text not null default 'active' check (interruption_preference in ('passive', 'active', 'timeSensitive')),
  snooze_minutes integer,
  sort_order integer not null default 0,
  created_at timestamptz not null,
  client_updated_at timestamptz not null,
  client_mutation_id uuid not null,
  is_deleted boolean not null default false,
  deleted_at timestamptz,
  payload_version integer not null default 1,
  revision bigint not null default 1,
  server_updated_at timestamptz not null default now(),
  server_seq bigint not null default nextval('public.kue_sync_seq'),
  primary key (id, user_id),
  foreign key (event_id, user_id) references public.sync_events (id, user_id) on delete cascade,
  foreign key (task_id, user_id) references public.sync_tasks (id, user_id) on delete cascade
);

create index if not exists sync_notification_rules_event_idx on public.sync_notification_rules (event_id, user_id) where event_id is not null;
create index if not exists sync_notification_rules_task_idx on public.sync_notification_rules (task_id, user_id) where task_id is not null;
create index if not exists sync_notification_rules_user_seq_idx on public.sync_notification_rules (user_id, server_seq);

drop trigger if exists sync_notification_rules_touch_revision on public.sync_notification_rules;
create trigger sync_notification_rules_touch_revision
  before insert or update on public.sync_notification_rules
  for each row execute function public.touch_sync_revision();

-- ============================================================================================
-- 6. Row Level Security — every table, owner-only, no client-controlled DELETE anywhere
-- ============================================================================================

-- A `security invoker` function's own DML statements execute *as the calling role* and are
-- therefore themselves subject to RLS on the underlying table — this is precisely why invoker
-- is safe to prefer here (requirement F): `push_event_graph`/etc. below have no special
-- privilege of their own at all, only what these policies grant `authenticated` directly, so a
-- bug inside one of those functions can never reach another user's row any more than a raw
-- PostgREST call could. There is deliberately no DELETE policy anywhere — every deletion is an
-- UPDATE setting `is_deleted`/`deleted_at` (already covered by the update policy below), never
-- a real `DELETE`; only the `on delete cascade` from `auth.users` (account deletion) removes a
-- row outright.
do $$
declare
  synced_table text;
begin
  foreach synced_table in array array['sync_events', 'sync_tasks', 'sync_schedules', 'sync_recurrence_exclusions', 'sync_notification_rules']
  loop
    execute format('alter table public.%I enable row level security', synced_table);

    execute format('drop policy if exists "select own rows" on public.%I', synced_table);
    execute format(
      'create policy "select own rows" on public.%I for select to authenticated using (auth.uid() = user_id)',
      synced_table
    );

    execute format('drop policy if exists "insert own rows" on public.%I', synced_table);
    execute format(
      'create policy "insert own rows" on public.%I for insert to authenticated with check (auth.uid() = user_id)',
      synced_table
    );

    execute format('drop policy if exists "update own rows" on public.%I', synced_table);
    execute format(
      'create policy "update own rows" on public.%I for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id)',
      synced_table
    );
  end loop;
end;
$$;

-- `sync_tasks`/`sync_schedules`/`sync_notification_rules` additionally require their parent
-- `sync_events`/`sync_tasks` row to already belong to the same caller — requirement F: "child
-- rows cannot be attached to another user's parent." `user_id = auth.uid()` alone would let a
-- caller attach a task to *someone else's* event as long as they stamped their own `user_id`
-- on the task row itself — this is now *also* rejected at the schema level by each child
-- table's own composite foreign key (section 2/3/5 above: `(event_id, user_id) references
-- sync_events (id, user_id)` can never be satisfied by an event id that belongs to a different
-- `user_id`), but these `with check` clauses are kept as a second, independent layer — a
-- defense-in-depth pairing, not a redundancy to prune. Re-declaring the whole `insert`/
-- `update` policy (rather than adding a second, separate policy) because Postgres combines
-- multiple permissive policies for the same command with OR, which would make the *narrower*
-- check meaningless once any wider one exists.
drop policy if exists "insert own rows" on public.sync_tasks;
create policy "insert own rows" on public.sync_tasks for insert to authenticated
  with check (
    auth.uid() = user_id
    and exists (select 1 from public.sync_events e where e.id = event_id and e.user_id = auth.uid())
  );
drop policy if exists "update own rows" on public.sync_tasks;
create policy "update own rows" on public.sync_tasks for update to authenticated
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and exists (select 1 from public.sync_events e where e.id = event_id and e.user_id = auth.uid())
  );

drop policy if exists "insert own rows" on public.sync_schedules;
create policy "insert own rows" on public.sync_schedules for insert to authenticated
  with check (
    auth.uid() = user_id
    and exists (select 1 from public.sync_events e where e.id = event_id and e.user_id = auth.uid())
  );
drop policy if exists "update own rows" on public.sync_schedules;
create policy "update own rows" on public.sync_schedules for update to authenticated
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and exists (select 1 from public.sync_events e where e.id = event_id and e.user_id = auth.uid())
  );

drop policy if exists "insert own rows" on public.sync_notification_rules;
create policy "insert own rows" on public.sync_notification_rules for insert to authenticated
  with check (
    auth.uid() = user_id
    and (
      (event_id is not null and exists (select 1 from public.sync_events e where e.id = event_id and e.user_id = auth.uid()))
      or
      (task_id is not null and exists (select 1 from public.sync_tasks t where t.id = task_id and t.user_id = auth.uid()))
    )
  );
drop policy if exists "update own rows" on public.sync_notification_rules;
create policy "update own rows" on public.sync_notification_rules for update to authenticated
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and (
      (event_id is not null and exists (select 1 from public.sync_events e where e.id = event_id and e.user_id = auth.uid()))
      or
      (task_id is not null and exists (select 1 from public.sync_tasks t where t.id = task_id and t.user_id = auth.uid()))
    )
  );

-- ============================================================================================
-- 7. Atomic push — one event graph (event + its tasks + schedule + notification rules) per
--    call, `security invoker` so `auth.uid()` inside always resolves to the real caller and
--    every write still passes through the RLS policies above via this function's own explicit
--    `where user_id = auth.uid()` guards (requirement F: "prefer security-invoker functions").
--
--    Optimistic concurrency and idempotency (Phase 5 correction — this section was rewritten
--    end to end):
--
--    * `expected_revision = 0` means "I believe this row does not exist yet" — nothing else.
--      It is CREATE-ONLY. If a row already exists for this `(id, user_id)`, `expected_revision
--      = 0` is never itself permission to overwrite it — that would let a client with a stale
--      or simply-never-pulled local state blindly clobber a row it has no proof it has ever
--      seen. The one exception is the very next bullet.
--    * `client_mutation_id` is this push's own idempotency key. Before making the create/
--      update/conflict decision, the function looks up any existing row's *last-applied*
--      `client_mutation_id`. If the incoming one matches, this call is a verified retry of the
--      exact mutation that already succeeded — it returns the row's current revision
--      completely untouched: no re-insert, no revision bump, no rewriting of tasks/schedule/
--      notification rules, and never reported as a conflict. This is what makes a client's
--      "did my last push actually land?" retry after a dropped response safe to repeat freely.
--    * Any other case where a row already exists and either `expected_revision = 0` or
--      `expected_revision` doesn't match the row's current `revision` is a genuine conflict —
--      the caller's local state disagrees with the server's, and it finds out the real current
--      state on its next pull rather than winning a race it didn't actually win.
--    * A row that does not yet exist with `expected_revision <> 0` is also a conflict, not a
--      create — the client believes a revision already exists that the server has never seen
--      (a mismatch no legitimate create could produce).
--
--    The existing-row lookup below uses `select ... for update`, taking a row lock for the
--    rest of this call's transaction — this is what makes the check-then-decide-then-write
--    sequence atomic against a second concurrent push for the same `(id, user_id)` racing it.
--
--    Requirement G's trade-off, stated explicitly: **one event graph is one transaction**, not
--    the whole multi-event batch. A PL/pgSQL function body is already one implicit transaction
--    per call, so pushing N event graphs as N separate `push_event_graph` calls (the client's
--    own loop, not a single N-graph RPC) gives exactly this: one malformed/rejected graph
--    aborts and reports failure for *that graph only* — the other N-1 calls already succeeded
--    or fail independently, never sharing a transaction that would roll all of them back
--    together. The alternative (one RPC taking an array of N graphs, wrapping the whole thing
--    in one function-level transaction) was rejected specifically because it violates
--    "one invalid event graph must not silently corrupt or delete unrelated graphs" — a single
--    bad graph in an all-or-nothing transaction would roll back every good one alongside it.
-- ============================================================================================

create or replace function public.push_event_graph(payload jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_event_id uuid;
  v_expected_revision bigint;
  v_incoming_mutation_id uuid;
  v_existing_revision bigint;
  v_existing_mutation_id uuid;
  v_new_revision bigint;
  v_task jsonb;
  v_rule jsonb;
  v_incoming_task_ids uuid[];
  v_incoming_rule_ids uuid[];
begin
  if auth.uid() is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;

  v_event_id := (payload ->> 'id')::uuid;
  v_expected_revision := coalesce((payload ->> 'expectedRevision')::bigint, 0);
  v_incoming_mutation_id := coalesce((payload ->> 'clientMutationID')::uuid, gen_random_uuid());

  -- Lock and inspect any existing row for this account's (id, user_id) up front, so the
  -- create/update/idempotent-replay/conflict decision below is made atomically with every
  -- write that follows it — a losing branch (conflict, or a recognized replay) never touches a
  -- single task, schedule, or notification-rule row for this event.
  select revision, client_mutation_id into v_existing_revision, v_existing_mutation_id
    from public.sync_events
   where id = v_event_id and user_id = auth.uid()
   for update;

  if v_existing_revision is not null and v_existing_mutation_id = v_incoming_mutation_id then
    -- Idempotent replay of the exact mutation that already succeeded: the graph on the server
    -- is already exactly what this call would produce, so return the original revision
    -- untouched. Never re-applied, never bumped, never a conflict.
    return jsonb_build_object('id', v_event_id, 'revision', v_existing_revision, 'conflict', false);
  end if;

  if v_existing_revision is null then
    if v_expected_revision <> 0 then
      -- The client believes a revision already exists; the server has never seen this row (or
      -- it was removed at the account level). Never treated as a fresh create.
      return jsonb_build_object('id', v_event_id, 'conflict', true);
    end if;
    -- Falls through to the create path below.
  else
    if v_expected_revision = 0 or v_expected_revision <> v_existing_revision then
      -- `expectedRevision = 0` against an EXISTING row is never permission to overwrite it
      -- (the Phase 5 correction this whole section exists for) — nor is any other stale,
      -- non-matching revision, unless it was the exact same mutation retried, already handled
      -- above.
      return jsonb_build_object('id', v_event_id, 'conflict', true);
    end if;
  end if;

  insert into public.sync_events (
    id, user_id, title, event_type, start_date, end_date, estimated_duration_minutes, is_all_day,
    time_zone_identifier, location, notes, source, priority, is_cancelled, cancelled_at,
    is_manually_completed, manually_completed_at, recurrence_frequency, recurrence_interval,
    recurrence_end_kind, recurrence_end_date, recurrence_end_occurrence_count, series_id,
    recurrence_anchor_date, is_recurrence_exception, is_skipped, skipped_at, created_at,
    client_updated_at, client_mutation_id, is_deleted, deleted_at
  ) values (
    v_event_id, auth.uid(), payload ->> 'title', payload ->> 'eventType',
    (payload ->> 'startDate')::timestamptz, (payload ->> 'endDate')::timestamptz,
    coalesce((payload ->> 'estimatedDurationMinutes')::integer, 0),
    coalesce((payload ->> 'isAllDay')::boolean, false), payload ->> 'timeZoneIdentifier',
    payload ->> 'location', payload ->> 'notes', payload ->> 'source', payload ->> 'priority',
    coalesce((payload ->> 'isCancelled')::boolean, false), (payload ->> 'cancelledAt')::timestamptz,
    coalesce((payload ->> 'isManuallyCompleted')::boolean, false), (payload ->> 'manuallyCompletedAt')::timestamptz,
    payload ->> 'recurrenceFrequency', (payload ->> 'recurrenceInterval')::integer,
    payload ->> 'recurrenceEndKind', (payload ->> 'recurrenceEndDate')::timestamptz,
    (payload ->> 'recurrenceEndOccurrenceCount')::integer, (payload ->> 'seriesID')::uuid,
    (payload ->> 'recurrenceAnchorDate')::timestamptz,
    coalesce((payload ->> 'isRecurrenceException')::boolean, false),
    coalesce((payload ->> 'isSkipped')::boolean, false), (payload ->> 'skippedAt')::timestamptz,
    coalesce((payload ->> 'createdAt')::timestamptz, now()),
    coalesce((payload ->> 'clientUpdatedAt')::timestamptz, now()),
    v_incoming_mutation_id,
    coalesce((payload ->> 'isDeleted')::boolean, false), (payload ->> 'deletedAt')::timestamptz
  )
  on conflict (id, user_id) do update set
    title = excluded.title, event_type = excluded.event_type, start_date = excluded.start_date,
    end_date = excluded.end_date, estimated_duration_minutes = excluded.estimated_duration_minutes,
    is_all_day = excluded.is_all_day, time_zone_identifier = excluded.time_zone_identifier,
    location = excluded.location, notes = excluded.notes, source = excluded.source,
    priority = excluded.priority, is_cancelled = excluded.is_cancelled, cancelled_at = excluded.cancelled_at,
    is_manually_completed = excluded.is_manually_completed, manually_completed_at = excluded.manually_completed_at,
    recurrence_frequency = excluded.recurrence_frequency, recurrence_interval = excluded.recurrence_interval,
    recurrence_end_kind = excluded.recurrence_end_kind, recurrence_end_date = excluded.recurrence_end_date,
    recurrence_end_occurrence_count = excluded.recurrence_end_occurrence_count, series_id = excluded.series_id,
    recurrence_anchor_date = excluded.recurrence_anchor_date, is_recurrence_exception = excluded.is_recurrence_exception,
    is_skipped = excluded.is_skipped, skipped_at = excluded.skipped_at,
    client_updated_at = excluded.client_updated_at, client_mutation_id = excluded.client_mutation_id,
    is_deleted = excluded.is_deleted, deleted_at = excluded.deleted_at
  where sync_events.user_id = auth.uid()
  returning revision into v_new_revision;

  if v_new_revision is null then
    -- Unreachable in practice given the locked pre-check above (this account's row for this id
    -- either didn't exist, in which case the plain INSERT branch always applies, or matched
    -- the expected revision exactly) — kept as a last-resort safety net, never surfaced as a
    -- silent success.
    return jsonb_build_object('id', v_event_id, 'conflict', true);
  end if;

  -- Tasks — replace-in-place by id; a task id present locally but absent from this payload is
  -- soft-deleted here (the client always sends its *current, complete* task list for this
  -- event, so absence here is a real, intentional deletion — never a partial/truncated send).
  v_incoming_task_ids := array(select (t ->> 'id')::uuid from jsonb_array_elements(coalesce(payload -> 'tasks', '[]'::jsonb)) as t);

  for v_task in select * from jsonb_array_elements(coalesce(payload -> 'tasks', '[]'::jsonb))
  loop
    insert into public.sync_tasks (
      id, user_id, event_id, title, due_date, is_completed, completed_at, offset_label,
      sort_order, created_at, client_updated_at, client_mutation_id, is_deleted, deleted_at
    ) values (
      (v_task ->> 'id')::uuid, auth.uid(), v_event_id, v_task ->> 'title',
      (v_task ->> 'dueDate')::timestamptz, coalesce((v_task ->> 'isCompleted')::boolean, false),
      (v_task ->> 'completedAt')::timestamptz, coalesce(v_task ->> 'offsetLabel', ''),
      coalesce((v_task ->> 'sortOrder')::integer, 0), coalesce((v_task ->> 'createdAt')::timestamptz, now()),
      coalesce((v_task ->> 'clientUpdatedAt')::timestamptz, now()),
      coalesce((v_task ->> 'clientMutationID')::uuid, gen_random_uuid()), false, null
    )
    on conflict (id, user_id) do update set
      event_id = v_event_id, title = excluded.title, due_date = excluded.due_date,
      is_completed = excluded.is_completed, completed_at = excluded.completed_at,
      offset_label = excluded.offset_label, sort_order = excluded.sort_order,
      client_updated_at = excluded.client_updated_at, client_mutation_id = excluded.client_mutation_id,
      is_deleted = false, deleted_at = null
    where sync_tasks.user_id = auth.uid();
  end loop;

  update public.sync_tasks
     set is_deleted = true, deleted_at = now()
   where event_id = v_event_id and user_id = auth.uid() and not is_deleted
     and (array_length(v_incoming_task_ids, 1) is null or not (id = any(v_incoming_task_ids)));

  -- Schedule — at most one per event; absent payload means "no schedule," soft-deleting any
  -- existing row for this event (a schedule with no rules is represented as an empty array,
  -- not as an absent schedule, so this only fires on a genuine regenerate-to-none).
  if payload ? 'schedule' and payload -> 'schedule' is not null then
    insert into public.sync_schedules (
      id, user_id, event_id, template_type, rules, is_custom, generated_at,
      created_at, client_updated_at, client_mutation_id, is_deleted, deleted_at
    ) values (
      (payload -> 'schedule' ->> 'id')::uuid, auth.uid(), v_event_id,
      payload -> 'schedule' ->> 'templateType', coalesce(payload -> 'schedule' -> 'rules', '[]'::jsonb),
      coalesce((payload -> 'schedule' ->> 'isCustom')::boolean, false),
      coalesce((payload -> 'schedule' ->> 'generatedAt')::timestamptz, now()),
      coalesce((payload -> 'schedule' ->> 'createdAt')::timestamptz, now()),
      coalesce((payload -> 'schedule' ->> 'clientUpdatedAt')::timestamptz, now()),
      coalesce((payload -> 'schedule' ->> 'clientMutationID')::uuid, gen_random_uuid()), false, null
    )
    on conflict (event_id, user_id) do update set
      template_type = excluded.template_type, rules = excluded.rules, is_custom = excluded.is_custom,
      generated_at = excluded.generated_at, client_updated_at = excluded.client_updated_at,
      client_mutation_id = excluded.client_mutation_id, is_deleted = false, deleted_at = null
    where sync_schedules.user_id = auth.uid();
  else
    update public.sync_schedules set is_deleted = true, deleted_at = now()
     where event_id = v_event_id and user_id = auth.uid() and not is_deleted;
  end if;

  -- Notification rules owned by this event or one of its tasks — same replace-by-id-within-
  -- scope semantics as tasks above.
  v_incoming_rule_ids := array(select (r ->> 'id')::uuid from jsonb_array_elements(coalesce(payload -> 'notificationRules', '[]'::jsonb)) as r);

  for v_rule in select * from jsonb_array_elements(coalesce(payload -> 'notificationRules', '[]'::jsonb))
  loop
    insert into public.sync_notification_rules (
      id, user_id, event_id, task_id, anchor, offset_direction, offset_quantity, offset_unit,
      absolute_date, is_enabled, custom_title, custom_body, sound, interruption_preference,
      snooze_minutes, sort_order, created_at, client_updated_at, client_mutation_id, is_deleted, deleted_at
    ) values (
      (v_rule ->> 'id')::uuid, auth.uid(),
      case when v_rule ->> 'taskID' is null then v_event_id else null end,
      (v_rule ->> 'taskID')::uuid,
      v_rule ->> 'anchor', v_rule ->> 'offsetDirection', coalesce((v_rule ->> 'offsetQuantity')::integer, 0),
      v_rule ->> 'offsetUnit', (v_rule ->> 'absoluteDate')::timestamptz,
      coalesce((v_rule ->> 'isEnabled')::boolean, true), v_rule ->> 'customTitle', v_rule ->> 'customBody',
      coalesce(v_rule ->> 'sound', 'defaultSound'), coalesce(v_rule ->> 'interruptionPreference', 'active'),
      (v_rule ->> 'snoozeMinutes')::integer, coalesce((v_rule ->> 'sortOrder')::integer, 0),
      coalesce((v_rule ->> 'createdAt')::timestamptz, now()), coalesce((v_rule ->> 'clientUpdatedAt')::timestamptz, now()),
      coalesce((v_rule ->> 'clientMutationID')::uuid, gen_random_uuid()), false, null
    )
    on conflict (id, user_id) do update set
      event_id = case when v_rule ->> 'taskID' is null then v_event_id else null end,
      task_id = (v_rule ->> 'taskID')::uuid,
      anchor = excluded.anchor, offset_direction = excluded.offset_direction,
      offset_quantity = excluded.offset_quantity, offset_unit = excluded.offset_unit,
      absolute_date = excluded.absolute_date, is_enabled = excluded.is_enabled,
      custom_title = excluded.custom_title, custom_body = excluded.custom_body, sound = excluded.sound,
      interruption_preference = excluded.interruption_preference, snooze_minutes = excluded.snooze_minutes,
      sort_order = excluded.sort_order, client_updated_at = excluded.client_updated_at,
      client_mutation_id = excluded.client_mutation_id, is_deleted = false, deleted_at = null
    where sync_notification_rules.user_id = auth.uid();
  end loop;

  update public.sync_notification_rules
     set is_deleted = true, deleted_at = now()
   where user_id = auth.uid() and not is_deleted
     and ((event_id = v_event_id) or (task_id in (select id from public.sync_tasks where event_id = v_event_id and user_id = auth.uid())))
     and (array_length(v_incoming_rule_ids, 1) is null or not (id = any(v_incoming_rule_ids)));

  return jsonb_build_object('id', v_event_id, 'revision', v_new_revision, 'conflict', false);
exception
  when others then
    -- Never a raw error message (which could in principle echo payload content) — a short,
    -- safe code only. The PL/pgSQL function boundary itself is what gives this call its
    -- per-graph transactional isolation (see this function's own header) — an exception here
    -- rolls back only this one event graph's writes, never anything from a sibling call.
    return jsonb_build_object('id', v_event_id, 'error', 'push_failed');
end;
$$;

revoke all on function public.push_event_graph(jsonb) from public;
grant execute on function public.push_event_graph(jsonb) to authenticated;

-- ============================================================================================
-- 7a. Pure event deletion — a bare id, no content payload. `push_event_graph` above requires
--     every NOT NULL column (title, event_type, ...), which a local device no longer has once
--     it has deleted its own copy of the event; this is the lightweight counterpart for exactly
--     that case. Already account-scoped (`where id = p_id and user_id = auth.uid()` names both
--     halves of the composite key explicitly), so this function needed no change for the
--     composite-key correction above. Cascades through `sync_tasks`/`sync_schedules`/
--     `sync_notification_rules` automatically? No — deliberately does **not** cascade a
--     soft-delete to children automatically (a soft-delete UPDATE, unlike a real DELETE, never
--     fires `ON DELETE CASCADE`): the client already knows its own full child list and pushes
--     their removal the same way any other edit disappears from a graph push, so this function
--     only needs to mark the event row itself.
-- ============================================================================================

create or replace function public.push_event_deletion(p_id uuid)
returns jsonb
language sql
security invoker
set search_path = public
as $$
  update public.sync_events set is_deleted = true, deleted_at = now()
   where id = p_id and user_id = auth.uid()
  returning jsonb_build_object('id', id, 'revision', revision);
$$;

revoke all on function public.push_event_deletion(uuid) from public;
grant execute on function public.push_event_deletion(uuid) to authenticated;

-- ============================================================================================
-- 8. Atomic push — recurrence exclusions (create-only, so no revision/conflict handling is
--    needed — an id collision *within one account* here can only mean a harmless idempotent
--    retry of the exact same exclusion, per the local model's own "immutable once made"
--    invariant; a different account can safely reuse the same id, per this migration's own
--    composite-key correction above). Requirement G/4 (Phase 5 correction): returns a truthful
--    per-item result for every exclusion in the batch, never a bare aggregate count — a batch-
--    wide HTTP 2xx from this RPC was never proof every exclusion in it actually applied.
-- ============================================================================================

create or replace function public.push_recurrence_exclusions(payload jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_item jsonb;
  v_id uuid;
  v_results jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(payload -> 'exclusions', '[]'::jsonb))
  loop
    v_id := null;
    begin
      v_id := (v_item ->> 'id')::uuid;
      insert into public.sync_recurrence_exclusions (id, user_id, series_id, excluded_anchor_date, client_mutation_id)
      values (
        v_id, auth.uid(), (v_item ->> 'seriesID')::uuid,
        (v_item ->> 'excludedAnchorDate')::timestamptz,
        coalesce((v_item ->> 'clientMutationID')::uuid, gen_random_uuid())
      )
      on conflict (id, user_id) do nothing;
      v_results := v_results || jsonb_build_object('id', v_id, 'succeeded', true);
    exception when others then
      -- One malformed exclusion in the batch never blocks or falsifies the result of the rest
      -- — each is its own exception-scoped insert and its own truthfully-reported result, not
      -- a shared transaction or a count that silently drops the failure.
      v_results := v_results || jsonb_build_object('id', v_id, 'succeeded', false, 'error', 'push_failed');
    end;
  end loop;

  return jsonb_build_object('results', v_results);
end;
$$;

revoke all on function public.push_recurrence_exclusions(jsonb) from public;
grant execute on function public.push_recurrence_exclusions(jsonb) to authenticated;

-- ============================================================================================
-- 9. Explicit notification-rule tombstone push — requirement I: "an explicit tombstone
--    mechanism for Notification Rules rather than inferring deletion from absence." A rule id
--    deleted locally is pushed here directly (in addition to the owning event's next graph
--    push already omitting it from `notificationRules`) so deletion is never solely inferred.
--    Requirement G/4 (Phase 5 correction): returns a truthful per-item result for every rule id
--    in the batch, distinguishing "just deleted," "already deleted" (a harmless retry — the
--    goal state already holds), and "no such row for this account" (truthfully reported as a
--    failure, never silently swallowed into an aggregate count).
-- ============================================================================================

create or replace function public.push_notification_rule_deletions(rule_ids uuid[])
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_id uuid;
  v_results jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;

  foreach v_id in array coalesce(rule_ids, array[]::uuid[])
  loop
    begin
      update public.sync_notification_rules
         set is_deleted = true, deleted_at = now()
       where id = v_id and user_id = auth.uid() and not is_deleted;

      if found then
        v_results := v_results || jsonb_build_object('id', v_id, 'succeeded', true);
      elsif exists (select 1 from public.sync_notification_rules where id = v_id and user_id = auth.uid()) then
        -- Already deleted — a harmless retry; the goal state already holds.
        v_results := v_results || jsonb_build_object('id', v_id, 'succeeded', true);
      else
        -- No such row for this account — nothing server-side to confirm; reported truthfully
        -- rather than folded into a success count.
        v_results := v_results || jsonb_build_object('id', v_id, 'succeeded', false, 'error', 'not_found');
      end if;
    exception when others then
      v_results := v_results || jsonb_build_object('id', v_id, 'succeeded', false, 'error', 'push_failed');
    end;
  end loop;

  return jsonb_build_object('results', v_results);
end;
$$;

revoke all on function public.push_notification_rule_deletions(uuid[]) from public;
grant execute on function public.push_notification_rule_deletions(uuid[]) to authenticated;

-- ============================================================================================
-- 10. Account-scoped cleanup — mirrors `delete-account`'s own reliance on `on delete cascade`
--     (supabase/functions/delete-account/): deleting the `auth.users` row cascades through
--     every table above automatically. No separate cleanup function is needed or added.
-- ============================================================================================
