import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authHeader = req.headers.get("Authorization");
  if (!supabaseUrl || !anonKey || !serviceRoleKey || !authHeader) {
    return json({ error: "Supabase function is not configured" }, 500);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const admin = createClient(supabaseUrl, serviceRoleKey);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) {
    return json({ error: "Authentication required" }, 401);
  }

  const folder = userData.user.id.toLowerCase();
  for (const bucket of ["avatars", "post-photos"]) {
    const cleanupError = await emptyUserFolder(admin, bucket, folder);
    if (cleanupError) {
      console.error(`Failed to empty ${bucket}/${folder}:`, cleanupError);
      return json({ error: "Account media could not be removed" }, 500);
    }
  }

  // Revoke refresh sessions before deletion. Existing access JWTs can live
  // until expiry, so database policies also require an active profile row.
  const { error: signOutError } = await userClient.auth.signOut({ scope: "global" });
  if (signOutError) console.error("Global sign out failed:", signOutError.message);

  const { error: deleteError } = await admin.auth.admin.deleteUser(userData.user.id, false);
  if (deleteError) {
    return json({ error: deleteError.message }, 400);
  }

  return json({ deleted: true });
  } catch (err) {
    console.error("delete-account unhandled error:", err);
    return json({ error: "internal error" }, 500);
  }
});

async function emptyUserFolder(
  admin: SupabaseClient<any, "public", "public", any, any>,
  bucket: string,
  folder: string,
) {
  while (true) {
    const { data, error } = await admin.storage.from(bucket).list(folder, {
      limit: 1000,
      offset: 0,
      sortBy: { column: "name", order: "asc" },
    });
    if (error) return error.message;

    const paths = (data ?? [])
      .filter((item) => item.id !== null)
      .map((item) => `${folder}/${item.name}`);
    if (paths.length === 0) return null;

    const { error: removeError } = await admin.storage.from(bucket).remove(paths);
    if (removeError) return removeError.message;
    if (paths.length < 1000) return null;
  }
}

function json(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
