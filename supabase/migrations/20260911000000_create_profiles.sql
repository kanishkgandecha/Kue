-- Kue 3.0 Phase 4 — docs/32-kue-3-accounts-and-backend-foundation.md "Database schema."
--
-- Creates the one table this phase needs: `profiles`, one row per `auth.users` row, created
-- automatically by a trigger right after registration (never directly by the client — there
-- is no INSERT policy below on purpose). Username normalization/validation is enforced twice,
-- deliberately: `Shared/Services/Accounts/UsernamePolicy.swift` gives instant client-side
-- feedback, and the CHECK/UNIQUE constraints here are the actual authority ("no race-prone
-- check-then-insert assumption" — requirement F). Keep the two definitions in sync by hand;
-- there's no code generation between them.
--
-- No event/task/notification-rule/backup/collaboration/sync tables are created here — out of
-- scope for this phase (requirement F's own explicit boundary).

-- ============================================================================================
-- 1. Table
-- ============================================================================================

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  -- Already normalized (lowercased, trimmed) before it ever reaches this column — see
  -- `UsernamePolicy.normalize(_:)`. Case-insensitive uniqueness therefore falls out of a plain
  -- unique index on this column; there is no separate "display casing."
  username text not null,
  display_name text,
  -- Reserved for a future avatar-upload feature — deliberately just a nullable URL column,
  -- no Supabase Storage bucket created (requirement: "do not enable paid services" — Storage
  -- egress/size is a paid-tier concern this phase doesn't need to take on).
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_length check (char_length(username) between 3 and 20),
  -- Mirrors `UsernamePolicy.validationError(for:)` exactly: lowercase letters/digits/
  -- underscores, starts with a letter, no trailing underscore. Consecutive underscores are
  -- rejected by the separate NOT LIKE check below (a single regex for "no doubled underscore"
  -- is easy to get subtly wrong; two simple, obviously-correct constraints are clearer).
  constraint profiles_username_format check (username ~ '^[a-z][a-z0-9_]*$' and username !~ '_$'),
  constraint profiles_username_no_double_underscore check (username not like '%\_\_%'),
  -- Mirrors `UsernamePolicy.reservedUsernames` — keep both lists identical by hand.
  constraint profiles_username_not_reserved check (
    username not in (
      'admin', 'root', 'support', 'help', 'api', 'kue', 'supabase',
      'null', 'undefined', 'settings', 'profile', 'me', 'system', 'moderator'
    )
  ),
  constraint profiles_username_key unique (username)
);

comment on table public.profiles is
  'Kue 3.0 Phase 4 — one row per auth.users, created by handle_new_user(). See docs/32-kue-3-accounts-and-backend-foundation.md.';

-- ============================================================================================
-- 2. updated_at maintenance
-- ============================================================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ============================================================================================
-- 3. Profile creation after registration (requirement F: "secure trigger/function... to
--    create the profile safely after registration, while handling retries and partially-
--    created states")
-- ============================================================================================

-- Extracted into its own function (not inlined in `handle_new_user` below) because it must be
-- checked in more than one place — the initial candidate *and* the collision-suffixed retry —
-- and both call sites need the exact same authority: every constraint on `public.profiles`
-- itself (format, length, no double/trailing underscore, not reserved), not just the format
-- regex a hardening pass found `handle_new_user` was previously checking alone. A candidate
-- that fails this check must never reach an `insert` — that's what let a reserved or
-- over-length username abort the *entire* `auth.users` insert this trigger runs inside with an
-- uncaught CHECK-constraint error, silently breaking registration for that user (a real defect
-- found by this migration's own verification queries, see supabase/VERIFICATION.md).
create or replace function public.is_valid_username_candidate(candidate text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select candidate ~ '^[a-z][a-z0-9_]{2,19}$'
     and candidate !~ '_$'
     and candidate not like '%\_\_%'
     and candidate not in (
       'admin', 'root', 'support', 'help', 'api', 'kue', 'supabase',
       'null', 'undefined', 'settings', 'profile', 'me', 'system', 'moderator'
     );
$$;

revoke all on function public.is_valid_username_candidate(text) from public;
-- Not directly client-callable by design (it's an internal helper only `handle_new_user` and
-- `is_username_available` below ever call) — no grant to anon/authenticated is needed for
-- those callers, since a `security definer` function's body runs as its owner, who already
-- retains its own default execute rights on every function it owns regardless of what PUBLIC
-- has. Revoking PUBLIC here only closes off *direct* RPC-style calls to it.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  desired_username text;
  final_username text;
begin
  desired_username := lower(trim(coalesce(new.raw_user_meta_data ->> 'username', '')));

  -- The client already validates this shape (`UsernamePolicy`) before ever calling signUp,
  -- but this function must never trust client input — a metadata value that fails *any* of
  -- this table's own constraints (not just the format regex — length, reserved-word, and
  -- double/trailing-underscore rules too) falls back to a deterministic, always-valid
  -- placeholder derived from the new user's own id, never a hard failure that would abort
  -- registration.
  if not public.is_valid_username_candidate(desired_username) then
    desired_username := 'user_' || substr(new.id::text, 1, 8);
  end if;

  final_username := desired_username;

  begin
    insert into public.profiles (id, username, display_name)
    values (new.id, final_username, nullif(new.raw_user_meta_data ->> 'display_name', ''));
  exception when unique_violation then
    -- Two people finishing registration with the same desired username in the same instant is
    -- a genuine, if rare, race — the unique constraint (not this function) is what actually
    -- catches it. The base is truncated to 13 characters *before* the 7-character suffix
    -- ("_" + 6 hex characters) is appended, so the result can never exceed the 20-character
    -- maximum regardless of how long `desired_username` was (a `desired_username` at or near
    -- the 20-character limit previously produced an over-length suffixed value here, which —
    -- exactly like the reserved-word case above — raised an uncaught CHECK-constraint error
    -- and aborted the entire registration). The result is re-validated against every
    -- constraint again (truncation can, in principle, leave a trailing underscore if the 13th
    -- base character was itself one); a candidate that still isn't valid falls back to a
    -- fully synthetic, always-valid, extremely-unlikely-to-collide-again value instead of
    -- trusting a second unchecked assumption.
    final_username := substr(desired_username, 1, 13) || '_' || substr(new.id::text, 1, 6);
    if not public.is_valid_username_candidate(final_username) then
      final_username := 'user_' || substr(md5(random()::text || clock_timestamp()::text), 1, 14);
    end if;

    begin
      insert into public.profiles (id, username, display_name)
      values (new.id, final_username, nullif(new.raw_user_meta_data ->> 'display_name', ''))
      on conflict (id) do nothing;
    exception when unique_violation then
      -- A second collision in a row is astronomically unlikely (this only re-fires if the
      -- fully-random fallback above also happens to already be taken) — one more attempt with
      -- a fresh random suffix rather than leaving the user permanently profile-less.
      final_username := 'user_' || substr(md5(random()::text || clock_timestamp()::text), 1, 14);
      insert into public.profiles (id, username, display_name)
      values (new.id, final_username, nullif(new.raw_user_meta_data ->> 'display_name', ''))
      on conflict (id) do nothing;
    end;
  end;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================================================
-- 4. Username availability (the one intentionally-exposed RPC — requirement F: "unless a
--    specific username-availability RPC is intentionally exposed")
-- ============================================================================================

create or replace function public.is_username_available(p_username text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  -- Not just "does no row already have this" — an invalid or reserved candidate must read as
  -- unavailable too (a hardening-pass fix: this previously returned true for e.g. "admin",
  -- since no row named "admin" can ever actually exist — `handle_new_user` would reject it —
  -- which misled a client into showing "available" for a name registration would silently
  -- never actually grant, always falling through to a random fallback username instead).
  select public.is_valid_username_candidate(lower(trim(p_username)))
     and not exists (
    select 1 from public.profiles where username = lower(trim(p_username))
  );
$$;

comment on function public.is_username_available(text) is
  'Kue 3.0 Phase 4 — client-callable (anon + authenticated) availability check. False for any
   candidate that is not already normalized-and-valid (format/length/reserved-word) *or* that
   is already taken. Returns only a boolean; never leaks which profile (if any) already holds
   the name, an id, or any other field. The profiles_username_key unique constraint remains
   authoritative regardless of what this returns a moment before a real registration/edit.';

-- Postgres grants EXECUTE on a newly created function to PUBLIC by default — explicitly
-- revoked here, then granted only to the two roles that are actually meant to call this
-- (requirement: never leave a function reachable by every role just because nothing said
-- otherwise). `anon` needs it for the pre-registration availability check; `authenticated`
-- needs it for the "Edit Profile" availability check.
revoke all on function public.is_username_available(text) from public;
grant execute on function public.is_username_available(text) to anon, authenticated;

-- ============================================================================================
-- 5. Row Level Security — requirement F: "A signed-in user must only be able to read and
--    update their own private profile... Do not expose email addresses publicly." (Email
--    lives in auth.users, never copied into this table at all, so there is nothing to leak
--    even if a policy here were ever written too loosely.)
-- ============================================================================================

alter table public.profiles enable row level security;

drop policy if exists "Profiles are selectable by their owner" on public.profiles;
create policy "Profiles are selectable by their owner"
  on public.profiles for select
  to authenticated
  using (auth.uid() = id);

drop policy if exists "Profiles are updatable by their owner" on public.profiles;
create policy "Profiles are updatable by their owner"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Deliberately no INSERT policy (rows are only ever created by `handle_new_user`, a
-- `security definer` function that bypasses RLS) and no DELETE policy (rows are only ever
-- removed by the `on delete cascade` from `auth.users`, driven by the `delete-account` Edge
-- Function — see supabase/functions/delete-account/). A client can never insert or delete a
-- profiles row directly, by any user, under any circumstance.
