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
