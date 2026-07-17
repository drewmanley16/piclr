import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const validSkillLevels = new Set(["beginner", "intermediate", "advanced", "dupr"]);
const firstNameMaxLength = 30;
const lastNameMaxLength = 40;
const combinedNameMaxLength = 60;
const usernameMinLength = 3;
const usernameMaxLength = 24;

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

  const body = await req.json().catch(() => null);
  const username = normalizeUsername(body?.username);
  const usernameError = validateUsername(username);

  if (body?.check_username_only === true) {
    if (usernameError) {
      return json({ error: usernameError }, 400);
    }
    const { data: conflicts, error: conflictError } = await admin
      .from("profiles")
      .select("id")
      .eq("username", username)
      .neq("id", userData.user.id)
      .limit(1);

    if (conflictError) {
      return json({ error: conflictError.message }, 400);
    }
    return json({ available: !conflicts || conflicts.length === 0 });
  }

  const firstName = cleanText(body?.first_name);
  const lastName = cleanText(body?.last_name);
  const legacyDisplayName = cleanText(body?.display_name);
  const hasStructuredName = typeof body?.first_name === "string" || typeof body?.last_name === "string";
  const displayName = hasStructuredName ? `${firstName} ${lastName}`.trim() : legacyDisplayName;
  const legacyName = splitName(legacyDisplayName);
  const storedFirstName = hasStructuredName ? firstName : legacyName.firstName;
  const storedLastName = hasStructuredName ? lastName : legacyName.lastName;
  const avatarInitials = cleanText(body?.avatar_initials).slice(0, 4) || initialsFrom(displayName);
  const skillLevel = String(body?.skill_level ?? "");
  const duprRating = body?.dupr_rating == null ? null : Number(body.dupr_rating);

  if (hasStructuredName) {
    const firstNameError = validateName(firstName, "First name", firstNameMaxLength);
    if (firstNameError) return json({ error: firstNameError }, 400);

    const lastNameError = validateName(lastName, "Last name", lastNameMaxLength);
    if (lastNameError) return json({ error: lastNameError }, 400);
  }
  if (!displayName || characterCount(displayName) < 2 || characterCount(displayName) > combinedNameMaxLength) {
    return json({ error: `Name must be 2-${combinedNameMaxLength} characters` }, 400);
  }
  if (usernameError) {
    return json({ error: usernameError }, 400);
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
    .eq("username", username)
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
        first_name: storedFirstName || null,
        last_name: storedLastName || null,
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

  if (profileError?.code === "23505") {
    return json({ error: "That username is taken" }, 409);
  }
  if (profileError) {
    return json({ error: profileError.message }, 400);
  }

  return json({ profile });
  } catch (err) {
    console.error("complete-onboarding unhandled error:", err);
    return json({ error: "internal error" }, 500);
  }
});

function cleanText(value: unknown) {
  if (typeof value !== "string") return "";
  return value.normalize("NFC").trim().replace(/\s+/g, " ");
}

function normalizeUsername(value: unknown) {
  if (typeof value !== "string") return "";
  return value.trim().toLowerCase();
}

function validateName(name: string, label: string, maximumLength: number) {
  if (!name) return `${label} is required`;
  if (characterCount(name) > maximumLength) {
    return `${label} can use up to ${maximumLength} characters`;
  }
  if (!/\p{L}/u.test(name)) return `${label} must include a letter`;
  if (!/^[\p{L}\p{M} .’'\-]+$/u.test(name)) {
    return "Names can use letters, spaces, apostrophes, hyphens, or periods";
  }
  return null;
}

function validateUsername(username: string) {
  if (characterCount(username) < usernameMinLength || characterCount(username) > usernameMaxLength) {
    return `Username must be ${usernameMinLength}-${usernameMaxLength} characters`;
  }
  if (!/^[a-z0-9_.]+$/.test(username)) {
    return "Username can use lowercase letters, numbers, underscores, and periods";
  }
  return null;
}

function characterCount(value: string) {
  return Array.from(value).length;
}

function initialsFrom(name: string) {
  const parts = name.split(" ").filter(Boolean).slice(0, 2);
  const letters = parts.map((part) => part[0]).join("");
  return (letters || "PB").toUpperCase();
}

function splitName(name: string) {
  const parts = name.split(/\s+/).filter(Boolean);
  return {
    firstName: parts.shift() ?? "",
    lastName: parts.join(" "),
  };
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
