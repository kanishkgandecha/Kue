// Kue 3.0 Phase 4 — docs/32-kue-3-accounts-and-backend-foundation.md "Account deletion."
//
// The smallest secure server-side path account deletion actually needs (requirement K): the
// app itself never holds a service-role key (SystemAccountProvider.deleteAccount just POSTs
// here with the caller's own access token), so deleting *any* Supabase Auth user requires
// admin.deleteUser, which requires the service-role key — that key only ever exists inside
// this function's own server-side runtime (Supabase injects it as an environment variable;
// it is never committed, logged, or returned to the client).
//
// Authenticates the caller from their own JWT (never trusts a client-supplied user id) and
// deletes *only* that caller — `admin.deleteUser(user.id)`, never a request-body id. Postgres's
// own `on delete cascade` on `public.profiles.id` (see the migration in ../../migrations/)
// removes the matching profile row in the same operation — no separate cleanup call needed.
//
// Deploy with: `supabase functions deploy delete-account` (see docs/32's own manual checklist
// — this file alone does not deploy itself).

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
// Supabase-managed secret, present automatically in every deployed Edge Function's own
// runtime — never set by hand, never present in this repository, never logged.
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405 });
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "missing_authorization" }), { status: 401 });
  }
  const accessToken = authorization.slice("Bearer ".length);

  // A client scoped to the *caller's own* token — used only to identify who is asking,
  // never to perform the deletion itself (an ordinary user's own JWT has no admin rights).
  const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
  const { data: userData, error: userError } = await callerClient.auth.getUser(accessToken);
  if (userError || !userData?.user) {
    // Never echoes the token or the raw Supabase error back to the caller.
    return new Response(JSON.stringify({ error: "invalid_session" }), { status: 401 });
  }
  const callerID = userData.user.id;

  // The one place the service-role key is ever used — a separate admin client, never
  // constructed from anything the request itself supplied.
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { error: deleteError } = await adminClient.auth.admin.deleteUser(callerID);
  if (deleteError) {
    return new Response(JSON.stringify({ error: "delete_failed" }), { status: 500 });
  }

  return new Response(JSON.stringify({ deleted: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
