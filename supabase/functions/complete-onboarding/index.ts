import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const validSkillLevels = new Set(["beginner", "intermediate", "advanced", "dupr"]);

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
  const displayName = cleanText(body?.display_name, 60);
  const username = cleanUsername(body?.username);
  const avatarInitials = cleanText(body?.avatar_initials, 4) || initialsFrom(displayName);
  const skillLevel = String(body?.skill_level ?? "");
  const duprRating = body?.dupr_rating == null ? null : Number(body.dupr_rating);

  if (!displayName || displayName.length < 2) {
    return json({ error: "Display name is required" }, 400);
  }
  if (!username || username.length < 3 || username.length > 24) {
    return json({ error: "Username must be 3-24 characters" }, 400);
  }
  if (!/^[a-z0-9_.]+$/.test(username)) {
    return json({ error: "Username can use letters, numbers, underscores, and periods" }, 400);
  }
  if (!validSkillLevels.has(skillLevel)) {
    return json({ error: "Skill level is required" }, 400);
  }
  if (skillLevel === "dupr" && (!duprRating || duprRating < 2 || duprRating > 8)) {
    return json({ error: "DUPR rating must be between 2.00 and 8.00" }, 400);
  }

  const user = userData.user;
  if (!user.phone) {
    return json({ error: "A verified phone number is required" }, 400);
  }

  const { data: conflicts, error: conflictError } = await admin
    .from("profiles")
    .select("id")
    .ilike("username", username)
    .neq("id", user.id)
    .limit(1);

  if (conflictError) {
    return json({ error: conflictError.message }, 400);
  }
  if (conflicts && conflicts.length > 0) {
    return json({ error: "That username is taken" }, 409);
  }

  const completedAt = new Date().toISOString();
  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .upsert(
      {
        id: user.id,
        username,
        display_name: displayName,
        avatar_initials: avatarInitials.toUpperCase(),
        skill_level: skillLevel,
        rating: skillLevel === "dupr" ? duprRating : null,
        onboarding_completed_at: completedAt,
      },
      { onConflict: "id" },
    )
    .select()
    .single();

  if (profileError) {
    return json({ error: profileError.message }, 400);
  }

  return json({ profile });
});

function cleanText(value: unknown, maxLength: number) {
  if (typeof value !== "string") return "";
  return value.trim().replace(/\s+/g, " ").slice(0, maxLength);
}

function cleanUsername(value: unknown) {
  if (typeof value !== "string") return "";
  return value
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/[^a-z0-9_.]/g, "");
}

function initialsFrom(name: string) {
  const parts = name.split(" ").filter(Boolean).slice(0, 2);
  const letters = parts.map((part) => part[0]).join("");
  return (letters || "PB").toUpperCase();
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
