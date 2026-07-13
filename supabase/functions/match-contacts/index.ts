import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
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

  const body = await req.json().catch(() => null);
  const phones = Array.isArray(body?.phones)
    ? [...new Set(body.phones.map(normalizePhone).filter(Boolean))]
    : [];

  if (phones.length === 0) {
    return json({ matches: [] });
  }
  if (phones.length > 500) {
    return json({ error: "Too many contacts in one request" }, 400);
  }

  const { data: lookupRows, error: lookupError } = await admin
    .rpc("match_phone_lookup", { phones });

  if (lookupError) {
    return json({ error: lookupError.message }, 400);
  }

  const rows = (lookupRows ?? []).filter((row) => row.profile_id !== userData.user.id);
  const profileIds = [...new Set(rows.map((row) => row.profile_id))];
  if (profileIds.length === 0) {
    return json({ matches: [] });
  }

  const { data: profiles, error: profilesError } = await admin
    .from("profiles")
    .select("id, username, display_name, avatar_initials, home_court, rating, skill_level, onboarding_completed_at, paddle, preferred_side")
    .in("id", profileIds)
    .not("onboarding_completed_at", "is", null);

  if (profilesError) {
    return json({ error: profilesError.message }, 400);
  }

  const profileById = new Map((profiles ?? []).map((profile) => [profile.id, profile]));
  const matches = rows
    .map((row) => {
      const profile = profileById.get(row.profile_id);
      return profile ? { phone: row.phone_e164, profile } : null;
    })
    .filter(Boolean);

  return json({ matches });
});

function normalizePhone(value: unknown) {
  if (typeof value !== "string") return null;
  const digits = value.replace(/\D/g, "");
  if (digits.length < 8 || digits.length > 15) return null;
  return `+${digits}`;
}

function json(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}
