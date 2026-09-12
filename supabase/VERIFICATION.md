# Supabase migration / RLS verification — Kue 3.0 Phase 4

Reproducible verification for `supabase/migrations/20260911000000_create_profiles.sql` —
requirement F: "Include SQL tests or clearly reproducible verification queries." None of this
was run against the real "Kue Development" project from this environment (no Supabase CLI/
network access here) — see docs/32's own "What Kanishk Must Do in Supabase" for running this
for real, ideally against a local `supabase start` instance first, never production.

## Setup

```bash
supabase start                      # local Postgres + Auth + PostgREST, isolated from prod
supabase db reset                   # applies every file in supabase/migrations/ from scratch
```

Then create two real test users (local instance only) via the Auth API or dashboard —
`alice@example.test` / `bob@example.test`, each with a password. Note their `id`s and grab a
fresh `access_token` for each via `POST /auth/v1/token?grant_type=password`.

## 1. Anonymous denial

```sql
-- Run as the anon role (no Authorization header, or the anon key only).
select * from public.profiles;
```
**Expected:** zero rows (RLS has no `select` policy for `anon` — only `authenticated`).

## 2. Cross-user read denial

```sql
-- As Bob (Authorization: Bearer <bob's access_token>), try to read Alice's row.
select * from public.profiles where id = '<alice_id>';
```
**Expected:** zero rows — the `using (auth.uid() = id)` clause on the select policy excludes it,
not an error, matching Postgres RLS's normal "filtered, not denied" behavior.

## 3. Cross-user update denial

```sql
-- As Bob, try to rename Alice's username.
update public.profiles set username = 'hijacked' where id = '<alice_id>';
```
**Expected:** `0 rows updated` — the `using`/`with check` clauses on the update policy both
require `auth.uid() = id`.

## 4. Owner read

```sql
-- As Alice.
select * from public.profiles where id = auth.uid();
```
**Expected:** exactly Alice's own row.

## 5. Owner update

```sql
-- As Alice.
update public.profiles set display_name = 'Alice A.' where id = auth.uid();
select display_name from public.profiles where id = auth.uid();
```
**Expected:** the update succeeds; `updated_at` also advances (the `set_updated_at` trigger).

## 6. Duplicate normalized username rejection

```sql
-- As Bob, try to take Alice's exact username.
update public.profiles set username = (select username from public.profiles where id = '<alice_id>') where id = auth.uid();
```
**Expected:** `ERROR: duplicate key value violates unique constraint "profiles_username_key"`.
Also verify case-insensitivity is moot because both are already normalized lowercase —
attempting to set `username = 'Alice'` (mixed case) should instead fail the
`profiles_username_format` CHECK (uppercase isn't in the allowed character class), proving a
casing trick can't bypass uniqueness by sneaking past normalization.

## 7. Username availability RPC

```sql
-- As anon (no session at all — this must work before a user exists).
select public.is_username_available('alice');   -- false, already taken
select public.is_username_available('brandnewname123'); -- true
select public.is_username_available('ADMIN');    -- false — a hardening-pass fix (was `true`
                                                  -- before it): "available" must mean "would
                                                  -- actually succeed if registered right now,"
                                                  -- not just "no row already has this exact
                                                  -- string." A reserved word, or anything that
                                                  -- fails the format/length rules, can never
                                                  -- become a real row (handle_new_user() would
                                                  -- reject it and fall back to a random name),
                                                  -- so it must never read as "available" either.
select public.is_username_available('ab');       -- false — too short (profiles_username_length)
select public.is_username_available('this_name_is_22_chars'); -- false — too long (max 20)
select public.is_username_available('bad__name');  -- false — double underscore
select public.is_username_available('bad_name_');  -- false — trailing underscore
```

## 7a. Grant hygiene — `is_username_available` is not reachable via the default PUBLIC grant

```sql
select has_function_privilege('public'::regrole, 'public.is_username_available(text)', 'execute');
```
**Expected:** `false` — Postgres grants EXECUTE on a newly created function to PUBLIC by
default; this migration explicitly revokes it and grants only to `anon`/`authenticated`
instead. A regression here (someone re-creating the function without the `revoke` line) would
silently make this `true` again — this is the reproducible check that catches it.

```sql
select has_function_privilege('anon'::regrole, 'public.is_username_available(text)', 'execute');
select has_function_privilege('authenticated'::regrole, 'public.is_username_available(text)', 'execute');
```
**Expected:** `true` for both — the two roles the RPC is actually meant to serve.

## 8. Account deletion cleanup

```sql
-- As a service-role connection (never as a client role) — simulates what the delete-account
-- Edge Function's admin client does.
select auth.admin_delete_user('<bob_id>'); -- or via the Auth Admin API
select count(*) from public.profiles where id = '<bob_id>';
```
**Expected:** `0` — the `on delete cascade` on `profiles.id references auth.users(id)` removes
the profile row automatically; no separate cleanup statement is needed or should be added.

## 9. Registration race (best-effort, not required to reproduce exactly)

Two `signUp` calls with the same `username` in `raw_user_meta_data` fired concurrently should
result in: both `auth.users` rows created (registration itself never fails on a username
collision), one `profiles` row with the original username, and one with the
`<username>_<6 hex chars>` fallback suffix from `handle_new_user`'s `exception when
unique_violation` branch — never a missing profile row for either user.

## 10. `handle_new_user()` hardening — reserved, malformed, maximum-length, and colliding
     desired usernames (a real hardening-pass fix — see this migration's own comments on
     `is_valid_username_candidate`/`handle_new_user`)

Each of these registers a real `auth.users` row with a `raw_user_meta_data->>'username'` that
should be rejected as the *literal* username, and checks that registration still succeeds with
some other valid, non-reserved fallback name — never an aborted signup.

```sql
-- 10a. Reserved desired username ("admin" passes the format/length regex on its own — the bug
-- this fixed: before the hardening pass, only the regex was checked, so this raised an
-- uncaught CHECK-constraint error here and rolled back the entire auth.users insert, meaning
-- the user couldn't even create an account).
-- Sign up (via the Auth API, not directly) with raw_user_meta_data = {"username": "admin"}.
select username from public.profiles where id = '<the new user id>';
```
**Expected:** the row exists (registration succeeded) and `username` is the `user_<8 hex>`
fallback — never the literal string `'admin'` (which the table's own
`profiles_username_not_reserved` constraint would reject).

```sql
-- 10b. Malformed desired username (uppercase, punctuation, leading digit — anything
-- `is_valid_username_candidate` rejects on format grounds alone).
-- Sign up with raw_user_meta_data = {"username": "1 Not Valid!"}.
select username from public.profiles where id = '<the new user id>';
```
**Expected:** the row exists; `username` is the `user_<8 hex>` fallback.

```sql
-- 10c. Maximum-length desired username that also collides with an existing row (the other bug
-- this fixed: a 20-character desired_username plus the old unconditional "_<6 hex>" suffix
-- produced a 27-character value, over profiles_username_length's 20-character maximum, raising
-- an uncaught CHECK-constraint error exactly like 10a).
-- First, register a real user with raw_user_meta_data = {"username": "abcdefghijklmnopqrst"}
-- (exactly 20 characters — the maximum a valid username can be) so a second signup with the
-- identical desired username actually collides.
-- Then sign up a second, different user with the same raw_user_meta_data = {"username":
-- "abcdefghijklmnopqrst"}.
select username, char_length(username) from public.profiles where id = '<the second user id>';
```
**Expected:** the second row exists; `username` is `abcdefghijklm_<6 hex>` (the first 13
characters of the 20-character desired name, plus the 7-character suffix — 20 characters
total, never longer), and `char_length(username) <= 20`.

## 11. `is_valid_username_candidate` matches every one of `profiles`' own constraints exactly

```sql
select public.is_valid_username_candidate('admin');            -- false (reserved)
select public.is_valid_username_candidate('ab');                -- false (too short)
select public.is_valid_username_candidate('this_name_is_22_chars'); -- false (too long)
select public.is_valid_username_candidate('bad__name');         -- false (double underscore)
select public.is_valid_username_candidate('bad_name_');         -- false (trailing underscore)
select public.is_valid_username_candidate('1notvalid');         -- false (doesn't start with a letter)
select public.is_valid_username_candidate('kanishk_g');         -- true
```

## 12. Grant hygiene — `is_valid_username_candidate` is an internal helper only, never
     client-callable

```sql
select has_function_privilege('public'::regrole, 'public.is_valid_username_candidate(text)', 'execute');
select has_function_privilege('anon'::regrole, 'public.is_valid_username_candidate(text)', 'execute');
select has_function_privilege('authenticated'::regrole, 'public.is_valid_username_candidate(text)', 'execute');
```
**Expected:** `false` for all three — this function only exists to be called *from inside*
`handle_new_user()`/`is_username_available()` (both `security definer`, both able to call it
regardless of PUBLIC's own grants, since a function's owner always retains execute rights on
what it owns); it was never meant to be reachable as its own RPC.

---

# Phase 5 — Cross-Device Sync Verification

Covers `supabase/migrations/20260912000000_create_sync_tables.sql` — five tables
(`sync_events`, `sync_tasks`, `sync_schedules`, `sync_recurrence_exclusions`,
`sync_notification_rules`), owner-only RLS, and three `security invoker` push RPCs. Same
disclosed limitation as Phase 4's own verification above: **none of this was run against a
real instance from this environment.**

**Phase 5 correction (this section was rewritten):** the first version of this migration and
this file both had a real defect — every synced table's primary key was the bare client-
generated `id` alone, not scoped to the owning account, and the original section 17 below
described a "hijack via RPC" scenario whose claimed outcome didn't even match the SQL as
written at the time (retrying `push_event_graph` with `expectedRevision: 0` against an
existing row actually silently overwrote it under the original code, contrary to what that
section claimed). Every table's real primary key is now the composite `(id, user_id)`, every
child table's foreign key to its parent is the matching composite pair, `push_event_graph`'s
optimistic-concurrency and idempotency logic was rewritten (see that function's own header
comment in the migration), and `push_recurrence_exclusions`/`push_notification_rule_deletions`
now return a per-item result array instead of a bare count. Sections 17, 18, and 21–24 below
are new or substantially rewritten to match; the rest are unchanged from the original pass.

## 13. Anonymous denial — every synced table

```sql
-- As anon (no session at all).
select * from public.sync_events;
select * from public.sync_tasks;
select * from public.sync_schedules;
select * from public.sync_recurrence_exclusions;
select * from public.sync_notification_rules;
```
**Expected:** zero rows from every table — no `select` policy exists for `anon` on any of them.

## 14. Cross-user read/update denial

```sql
-- Alice pushes an event (via push_event_graph, or a direct insert as herself for setup).
-- As Bob (Authorization: Bearer <bob's access_token>):
select * from public.sync_events where id = '<alice_event_id>';
update public.sync_events set title = 'hijacked' where id = '<alice_event_id>';
```
**Expected:** the `select` returns zero rows (filtered, not denied — normal RLS behavior); the
`update` affects `0 rows` (both the `using` and `with check` clauses require `auth.uid() =
user_id`).

## 15. Child rows cannot be attached to another user's parent

```sql
-- As Bob, attempt to insert a task pointing at Alice's own event id, with Bob's own user_id.
insert into public.sync_tasks (id, user_id, event_id, title, due_date, created_at, client_updated_at, client_mutation_id)
values (gen_random_uuid(), auth.uid(), '<alice_event_id>', 'Attached to someone else''s event', now(), now(), now(), gen_random_uuid());
```
**Expected:** rejected twice over now (Phase 5 correction — both layers are independently
sufficient, and this proves both):
1. The `sync_tasks` insert policy's own `with check` clause (`exists (select 1 from sync_events
   e where e.id = event_id and e.user_id = auth.uid())` — Alice's event is not owned by Bob, so
   this evaluates false) — `new row violates row-level security policy`.
2. Even if RLS were somehow bypassed, the table's own composite foreign key —
   `foreign key (event_id, user_id) references sync_events (id, user_id)` — has no row to point
   at: a row with `id = '<alice_event_id>'` exists, but never one with that `id` *and*
   `user_id = '<bob_id>'` together, so the constraint itself would raise `insert or update on
   table "sync_tasks" violates foreign key constraint` — a schema-level guarantee, not merely a
   policy that a future migration could accidentally loosen.

Repeat the equivalent for `sync_schedules`/`sync_notification_rules` against `sync_events`/
`sync_tasks` parents owned by another user.

## 16. Soft deletion cannot be used to escape ownership checks

```sql
-- As Bob, attempt to "delete" Alice's event by marking it deleted.
update public.sync_events set is_deleted = true, deleted_at = now() where id = '<alice_event_id>';
```
**Expected:** `0 rows updated` — the same owner-only `update` policy governs a soft-delete
exactly like any other update; there is no separate, looser path for it.

## 17. Identical client-generated UUIDs across two different accounts never collide or disclose
     each other (Phase 5 correction — replaces this section's original "hijack via RPC"
     framing, which predates the composite-key fix and no longer describes a real threat: a
     client-generated id is only ever unique *within* one account now, by design)

```sql
-- Alice pushes a real event first.
select public.push_event_graph('{"id": "<shared_id>", "expectedRevision": 0, "title": "Alice''s Event", "eventType": "generic", "startDate": "2026-01-01T00:00:00Z", "timeZoneIdentifier": "UTC", "source": "manual", "priority": "medium"}'::jsonb);
-- As Bob (a completely different account), push a *different* event using the exact same id.
select public.push_event_graph('{"id": "<shared_id>", "expectedRevision": 0, "title": "Bob''s Event", "eventType": "generic", "startDate": "2026-02-01T00:00:00Z", "timeZoneIdentifier": "UTC", "source": "manual", "priority": "medium"}'::jsonb);
```
**Expected:** both calls succeed, each returning `{"id": "<shared_id>", "revision": 1,
"conflict": false}` — Bob's push is a genuine create (his own account has never seen this id
before), never rejected and never treated as a conflict with Alice's row, because the two rows
are distinguished by their full `(id, user_id)` primary key, not by `id` alone. Confirm both
sides are simultaneously true and fully isolated:
```sql
-- As Alice.
select title from public.sync_events where id = '<shared_id>'; -- 'Alice''s Event', untouched
-- As Bob.
select title from public.sync_events where id = '<shared_id>'; -- 'Bob''s Event'
-- As Bob, attempt to read/update Alice's row directly by the shared id.
update public.sync_events set title = 'hijacked' where id = '<shared_id>' and user_id = '<alice_id>';
```
**Expected:** the last statement affects `0 rows` — RLS's `using (auth.uid() = user_id)`
excludes Alice's row from Bob's session regardless of `id` matching, so Bob can neither read
nor write it, and has no way to even learn Alice's row exists (no error, no row returned — the
same "filtered, not denied" RLS shape every other cross-user check in this file already
relies on). This is the concrete proof requirement 1 asked for: **Account A and Account B can
upload the same local UUID without collision or disclosure.**

## 18. Push RPCs never trust a client-supplied user_id

```sql
-- As Bob, call push_event_graph with a payload whose "id" is Alice's own event id (now
-- understood, per section 17, as simply Bob's own independent row sharing that id — the real
-- property being verified here is narrower and still essential: `user_id` on the resulting row
-- is always auth.uid(), never anything the client could pass in the payload itself, since the
-- payload has no user_id field the function even reads).
select public.push_event_graph('{"id": "<alice_event_id>", "expectedRevision": 0, "title": "Bob''s own row", "eventType": "generic", "startDate": "2026-01-01T00:00:00Z", "timeZoneIdentifier": "UTC", "source": "manual", "priority": "medium"}'::jsonb);
select user_id from public.sync_events where id = '<alice_event_id>' and user_id = '<bob_id>';
```
**Expected:** the row exists with `user_id = '<bob_id>'` — the function stamps `auth.uid()`
directly (`insert into ... values (v_event_id, auth.uid(), ...)`), and Alice's own row at that
same `id` (a different `user_id`) is completely unaffected, per section 17.

## 19. Optimistic concurrency — `expectedRevision = 0` is create-only, never permission to
     overwrite an existing row (Phase 5 correction — a real defect fixed: the original SQL let
     `expectedRevision = 0` match `ON CONFLICT DO UPDATE` unconditionally, silently overwriting
     any existing row a client merely claimed not to know the revision of)

```sql
-- As Alice, create a fresh event.
select public.push_event_graph('{"id": "<a-fresh-uuid>", "expectedRevision": 0, "title": "Original", "eventType": "generic", "startDate": "2026-01-01T00:00:00Z", "timeZoneIdentifier": "UTC", "source": "manual", "priority": "medium", "clientMutationID": "<mutation-A>"}'::jsonb);
-- Now push a *different* mutation against the same row, again claiming expectedRevision = 0.
select public.push_event_graph('{"id": "<the-same-uuid>", "expectedRevision": 0, "title": "Overwrite Attempt", "eventType": "generic", "startDate": "2026-01-01T00:00:00Z", "timeZoneIdentifier": "UTC", "source": "manual", "priority": "medium", "clientMutationID": "<mutation-B>"}'::jsonb);
```
**Expected:** the first call succeeds and returns `revision: 1`. The second call — a different
`clientMutationID`, so it is not a retry of the first — returns `{"conflict": true}`, and
`select title from public.sync_events where id = '<the-same-uuid>'` still returns `'Original'`,
completely untouched. `expectedRevision = 0` only ever creates a row that doesn't exist yet; it
is never read as "I don't know or don't care what's there, overwrite it anyway."

```sql
-- A row that does not exist yet, but the client claims a nonzero expectedRevision.
select public.push_event_graph('{"id": "<a-brand-new-uuid>", "expectedRevision": 5, "title": "Confused Client", "eventType": "generic", "startDate": "2026-01-01T00:00:00Z", "timeZoneIdentifier": "UTC", "source": "manual", "priority": "medium"}'::jsonb);
```
**Expected:** `{"conflict": true}` — never treated as a fresh create; the client's own belief
that revision 5 already exists contradicts the server having no row at all.

## 20. Idempotent replay — retrying the exact same mutation is a pure no-op, never a rewrite,
     revision bump, or conflict (Phase 5 correction — `client_mutation_id`-based idempotency
     did not exist at all before this pass; every retry previously either bumped the revision
     again or, combined with the section 19 defect, silently re-applied)

```sql
-- As Alice, push an event with one task.
select public.push_event_graph('{"id": "<a-fresh-uuid>", "expectedRevision": 0, "title": "Idempotency Check", "eventType": "generic", "startDate": "2026-01-01T00:00:00Z", "timeZoneIdentifier": "UTC", "source": "manual", "priority": "medium", "clientMutationID": "<mutation-X>", "tasks": [{"id": "<task-id>", "title": "Prep", "dueDate": "2025-12-31T00:00:00Z"}]}'::jsonb);
-- Retry the *exact* same call — same id, same expectedRevision, same clientMutationID, same content.
select public.push_event_graph('{"id": "<a-fresh-uuid>", "expectedRevision": 0, "title": "Idempotency Check", "eventType": "generic", "startDate": "2026-01-01T00:00:00Z", "timeZoneIdentifier": "UTC", "source": "manual", "priority": "medium", "clientMutationID": "<mutation-X>", "tasks": [{"id": "<task-id>", "title": "Prep", "dueDate": "2025-12-31T00:00:00Z"}]}'::jsonb);
select revision, client_mutation_id from public.sync_events where id = '<a-fresh-uuid>';
```
**Expected:** both calls return the identical `{"id": ..., "revision": 1, "conflict": false}` —
the second call is recognized as a replay of `<mutation-X>` (already the row's own stored
`client_mutation_id`) and returns the existing revision completely untouched: the final
`select` shows `revision = 1` (never bumped to 2), and a repeat `select id from public.sync_tasks
where event_id = '<a-fresh-uuid>'` still shows exactly one task row (never duplicated or
re-inserted).

```sql
-- Now push a genuinely different mutation, with a stale expectedRevision.
select public.push_event_graph('{"id": "<a-fresh-uuid>", "expectedRevision": 0, "title": "A Different Edit", "eventType": "generic", "startDate": "2026-01-01T00:00:00Z", "timeZoneIdentifier": "UTC", "source": "manual", "priority": "medium", "clientMutationID": "<mutation-Y>"}'::jsonb);
```
**Expected:** `{"conflict": true}` — a different `clientMutationID` against a stale
`expectedRevision` (0, when the row is already at revision 1) is a real conflict, not a replay.

## 21. Push idempotency, restated for a real update (not just a create) — a legitimate re-push
     of *changed* content with the correct current revision is a normal revision bump, never
     confused with an idempotent replay

```sql
-- Continuing from section 20 (the row is at revision 1). Push a real edit, current revision,
-- a *new* clientMutationID (this is a different logical edit, not a retry).
select public.push_event_graph('{"id": "<a-fresh-uuid>", "expectedRevision": 1, "title": "Edited For Real", "eventType": "generic", "startDate": "2026-01-01T00:00:00Z", "timeZoneIdentifier": "UTC", "source": "manual", "priority": "medium", "clientMutationID": "<mutation-Z>"}'::jsonb);
```
**Expected:** `{"id": ..., "revision": 2, "conflict": false}` — a matching current revision
with a new mutation id is applied and bumps the revision normally.

## 22. Partial batch failure — one malformed exclusion in a batch never falsifies or blocks its
     siblings' results (Phase 5 correction — `push_recurrence_exclusions` used to return only a
     bare `{"applied": N}` count, which a client could not map back to which specific items,
     if any, actually failed)

```sql
-- As Alice, one well-formed exclusion and one with a malformed seriesID.
select public.push_recurrence_exclusions('{"exclusions": [{"id": "<good-id>", "seriesID": "<real-series-id>", "excludedAnchorDate": "2026-01-01T00:00:00Z"}, {"id": "<bad-id>", "seriesID": "not-a-uuid", "excludedAnchorDate": "2026-01-01T00:00:00Z"}]}'::jsonb);
```
**Expected:** `{"results": [{"id": "<good-id>", "succeeded": true}, {"id": "<bad-id>",
"succeeded": false, "error": "push_failed"}]}` — the good exclusion is confirmed present
(`select id from public.sync_recurrence_exclusions where id = '<good-id>'` returns one row) and
the malformed one never was, and never silently counted as if it had been.

## 23. Cross-user child attachment, re-verified against the composite schema (section 15 covers
     the RLS/FK rejection itself; this confirms the same id is still independently attachable
     under each account, matching section 17's own event-level guarantee one level down)

```sql
-- Alice and Bob each independently attach a task using the same task id to their own,
-- separately-owned event with that same shared event id (per section 17).
-- As Alice: insert into sync_tasks (id, user_id, event_id, ...) values ('<shared_task_id>', auth.uid(), '<shared_event_id>', ...)
-- As Bob:   insert into sync_tasks (id, user_id, event_id, ...) values ('<shared_task_id>', auth.uid(), '<shared_event_id>', ...)
select user_id, title from public.sync_tasks where id = '<shared_task_id>' and user_id = '<alice_id>';
select user_id, title from public.sync_tasks where id = '<shared_task_id>' and user_id = '<bob_id>';
```
**Expected:** both inserts succeed independently (each satisfies its own account's RLS `with
check` and composite foreign key against that same account's own event row) and both selects
return their own account's distinct row — no collision, exactly like section 17's event-level
proof, one level down the graph.

## 24. Account-scoped tombstones — a soft-deleted row's account boundary is exactly as strict
     as a live row's

```sql
-- As Alice, soft-delete her own event.
select public.push_event_deletion('<alice_event_id>');
-- As Bob, attempt to read or "undelete" it by id.
select * from public.sync_events where id = '<alice_event_id>';
update public.sync_events set is_deleted = false where id = '<alice_event_id>';
```
**Expected:** Bob's `select` returns zero rows (filtered by RLS, not disclosed as "exists but
deleted" — Bob learns nothing about Alice's tombstone at all) and the `update` affects `0
rows`. Separately, confirm a *pull* only ever surfaces an account's own tombstones:
```sql
-- As Alice.
select id from public.sync_events where user_id = auth.uid() and is_deleted = true and server_seq >= 0;
```
**Expected:** exactly Alice's own deleted event ids — a tombstone is scoped by `(id, user_id)`
exactly like every other row, so Bob's independent deletion of his own same-id row (per section
17) never appears in, or is ever conflated with, Alice's own tombstone list.

## 25. Pull-cursor pagination determinism

```sql
-- As Alice, with at least 3 events already pushed.
select id, server_seq from public.sync_events where user_id = auth.uid() and server_seq >= 0 order by server_seq asc limit 2;
-- Repeat the identical query.
```
**Expected:** both calls return the exact same two rows in the exact same order — `server_seq`
is assigned once, at write time, and never changes on a read-only `select`, so pagination
against it is fully deterministic and repeat-safe.

## 26. Notification-rule ownership constraint

```sql
-- As Alice, attempt to insert a notification rule with both event_id and task_id set, or neither.
insert into public.sync_notification_rules (id, user_id, event_id, task_id, anchor, offset_direction, offset_unit, created_at, client_updated_at, client_mutation_id)
values (gen_random_uuid(), auth.uid(), '<alice_event_id>', '<alice_task_id>', 'eventStart', 'before', 'minutes', now(), now(), gen_random_uuid());
```
**Expected:** rejected by `sync_notification_rules_exactly_one_owner`'s own `check
((event_id is not null) <> (task_id is not null))` — `new row violates check constraint`.

## 27. `push_notification_rule_deletions` per-item results, including "already deleted" and
     "no such row" as distinct, truthful outcomes (Phase 5 correction — this RPC previously
     returned only `{"deleted": N}`, an aggregate count with no per-id mapping at all)

```sql
-- As Alice, with one real, live rule id and one id that doesn't belong to her (Bob's).
select public.push_notification_rule_deletions(array['<alice_rule_id>', '<bob_rule_id>']::uuid[]);
```
**Expected:** `{"results": [{"id": "<alice_rule_id>", "succeeded": true}, {"id":
"<bob_rule_id>", "succeeded": false, "error": "not_found"}]}` — Bob's rule is invisible to
Alice's own `where ... user_id = auth.uid()` scoping, reported truthfully as not found rather
than silently folded into the same success count as her own rule. Retrying the identical call
a second time:
```sql
select public.push_notification_rule_deletions(array['<alice_rule_id>']::uuid[]);
```
**Expected:** `{"results": [{"id": "<alice_rule_id>", "succeeded": true}]}` — already deleted,
reported as success again (the goal state already holds), never re-reported as a failure just
because there was no row left to actually update this time.

---

# Phase 6 — Cloud Profile and Productivity Statistics Verification

Covers `supabase/migrations/20260913000000_create_statistics_aggregates.sql` — one table
(`statistics_aggregates`), owner-only RLS on every verb including `delete`, no RPC (a plain
PostgREST upsert). Same disclosed limitation as Phases 4/5's own verification above: **none of
this was run against a real or local instance from this environment.**

## 28. Anonymous denial

```sql
-- As anon (no session at all).
select * from public.statistics_aggregates;
insert into public.statistics_aggregates (user_id, bucket_start) values ('<alice_id>', '2026-03-02');
```
**Expected:** the `select` returns zero rows; the `insert` is rejected — `anon` has no policy
on this table for either verb (only `authenticated` does).

## 29. Cross-user denial (read, write, and delete)

```sql
-- Alice has already uploaded one row for the current week.
-- As Bob:
select * from public.statistics_aggregates where user_id = '<alice_id>';
update public.statistics_aggregates set total_active_events = 999 where user_id = '<alice_id>';
delete from public.statistics_aggregates where user_id = '<alice_id>';
```
**Expected:** the `select` returns zero rows (filtered, not denied — normal RLS behavior); the
`update` affects `0 rows`; the `delete` affects `0 rows` — all three of `select`/`update`/
`delete`'s own `using (auth.uid() = user_id)` clauses exclude Alice's row from Bob's session.
Confirm afterward that Alice's row is completely unchanged:
```sql
-- As Alice.
select total_active_events from public.statistics_aggregates where user_id = auth.uid();
```

## 30. Same-user read/write

```sql
-- As Alice.
insert into public.statistics_aggregates (user_id, bucket_start, total_active_events, completed_events)
values (auth.uid(), '2026-03-02', 3, 1)
on conflict (user_id, bucket_start) do update set total_active_events = excluded.total_active_events, completed_events = excluded.completed_events;
select total_active_events, completed_events from public.statistics_aggregates where user_id = auth.uid() and bucket_start = '2026-03-02';
```
**Expected:** the insert succeeds (both `with check` clauses pass — `auth.uid() = user_id`),
and the final `select` returns exactly `(3, 1)`.

## 31. Idempotent upsert — a client-side PostgREST upsert, not a custom RPC

```sql
-- As Alice, simulating what SupabaseStatisticsTransport.upload actually sends: a POST to
-- /rest/v1/statistics_aggregates?on_conflict=user_id,bucket_start with header
-- "Prefer: resolution=merge-duplicates,return=minimal", body {"user_id": "<alice_id>",
-- "bucket_start": "2026-03-02", "total_active_events": 5, ...}. Equivalent raw SQL:
insert into public.statistics_aggregates (user_id, bucket_start, total_active_events)
values (auth.uid(), '2026-03-02', 5)
on conflict (user_id, bucket_start) do update set total_active_events = excluded.total_active_events;
-- Re-send the identical request a second time.
insert into public.statistics_aggregates (user_id, bucket_start, total_active_events)
values (auth.uid(), '2026-03-02', 5)
on conflict (user_id, bucket_start) do update set total_active_events = excluded.total_active_events;
select count(*) from public.statistics_aggregates where user_id = auth.uid() and bucket_start = '2026-03-02';
```
**Expected:** `count = 1` — the second, identical upload never creates a second row for the
same account/week; the table's own `primary key (user_id, bucket_start)` is the conflict
target `on_conflict=user_id,bucket_start` resolves against.

## 32. Invalid aggregate rejection

```sql
-- As Alice, each of these should be rejected by a CHECK constraint.
insert into public.statistics_aggregates (user_id, bucket_start, total_active_events) values (auth.uid(), '2026-03-09', -1);
insert into public.statistics_aggregates (user_id, bucket_start, task_completion_rate) values (auth.uid(), '2026-03-09', 1.5);
insert into public.statistics_aggregates (user_id, bucket_start, task_completion_rate) values (auth.uid(), '2026-03-09', -0.1);
insert into public.statistics_aggregates (user_id, bucket_start, current_streak, longest_streak) values (auth.uid(), '2026-03-09', 5, 2);
```
**Expected:** every one of the four `insert`s raises `new row for relation
"statistics_aggregates" violates check constraint` — a negative count
(`statistics_aggregates_total_active_events_check` et al.), a rate outside `[0, 1]`
(`statistics_aggregates_task_completion_rate_check`), and `current_streak > longest_streak`
(`statistics_aggregates_streak_order`) are all structurally impossible to store, not merely
discouraged by client-side validation.

## 33. Account deletion cascade

```sql
-- As a service-role connection (never as a client role) — simulates delete-account's own
-- admin client, exactly like Phase 4's own section 8.
select auth.admin_delete_user('<bob_id>');
select count(*) from public.statistics_aggregates where user_id = '<bob_id>';
```
**Expected:** `0` — `on delete cascade` on `statistics_aggregates.user_id references
auth.users(id)` removes every one of that account's aggregate rows automatically.

## 34. Cloud-statistics deletion without deleting the account or local events

```sql
-- As Alice, with several weeks of uploaded rows.
delete from public.statistics_aggregates where user_id = auth.uid();
select count(*) from public.statistics_aggregates where user_id = auth.uid();
select count(*) from public.profiles where id = auth.uid();
```
**Expected:** the aggregate count drops to `0`; the `profiles` row (and, by extension, the
`auth.users` account itself) is completely unaffected — "Delete Cloud Statistics" (requirement
F) is scoped to exactly this one table and never touches `profiles`, `auth.users`, or any
Phase 5 sync table. Local events are, by construction, never reachable from any Supabase table
at all (requirement A: they are never uploaded to begin with), so there is nothing server-side
that could delete them even accidentally.
