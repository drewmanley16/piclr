// Delivers an APNs push for a single `notifications` row. Invoked server-to-server
// by the on_notification_dispatch_push trigger (pg_net), never by a client.
//
// Required secrets (supabase secrets set ...):
//   PUSH_FUNCTION_SECRET  shared bearer that must match the DB's push_function_key
//   APNS_KEY              contents of the .p8 APNs auth key (PEM, incl. header/footer)
//   APNS_KEY_ID           the 10-char Key ID for that .p8
//   APNS_TEAM_ID          Apple Developer team id (X9H68STU8F)
//   APNS_BUNDLE_ID        com.pickleball.ai
//   APNS_HOST             api.push.apple.com (prod) or api.sandbox.push.apple.com (dev)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type NotificationRow = {
  id: string;
  user_id: string;
  actor_id: string | null;
  type: string;
  session_id: string | null;
  comment_id: string | null;
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const secret = Deno.env.get("PUSH_FUNCTION_SECRET");
  const auth = req.headers.get("Authorization") ?? "";
  if (!secret || auth !== `Bearer ${secret}`) {
    return json({ error: "Unauthorized" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) return json({ error: "Not configured" }, 500);

  const body = await req.json().catch(() => null);
  const notificationId = body?.notification_id;
  if (!notificationId) return json({ error: "notification_id required" }, 400);

  const admin = createClient(supabaseUrl, serviceRoleKey);

  // Load the notification.
  const { data: notif, error: notifErr } = await admin
    .from("notifications")
    .select("id, user_id, actor_id, type, session_id, comment_id")
    .eq("id", notificationId)
    .single<NotificationRow>();
  if (notifErr || !notif) return json({ error: "Notification not found" }, 404);

  // Recipient's device tokens.
  const { data: tokens } = await admin
    .from("device_tokens")
    .select("token")
    .eq("user_id", notif.user_id);
  if (!tokens || tokens.length === 0) return json({ delivered: 0, reason: "no tokens" });

  // Actor handle + optional comment body for the message text.
  let handle = "Someone";
  if (notif.actor_id) {
    const { data: actor } = await admin
      .from("profiles")
      .select("username")
      .eq("id", notif.actor_id)
      .single<{ username: string }>();
    if (actor?.username) handle = `@${actor.username}`;
  }
  let commentBody = "";
  if (notif.comment_id) {
    const { data: c } = await admin
      .from("comments")
      .select("body")
      .eq("id", notif.comment_id)
      .single<{ body: string }>();
    commentBody = c?.body ?? "";
  }

  const { title, message } = buildMessage(notif.type, handle, commentBody);

  const jwt = await apnsJWT();
  const host = Deno.env.get("APNS_HOST") ?? "api.push.apple.com";
  const bundleId = Deno.env.get("APNS_BUNDLE_ID") ?? "com.pickleball.ai";

  const payload = JSON.stringify({
    aps: { alert: { title, body: message }, sound: "default", badge: 1 },
    notification_id: notif.id,
    type: notif.type,
    session_id: notif.session_id,
    actor_id: notif.actor_id,
  });

  let delivered = 0;
  for (const { token } of tokens) {
    const res = await fetch(`https://${host}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      body: payload,
    });
    if (res.ok) {
      delivered++;
    } else if (res.status === 410 || res.status === 400) {
      // Unregistered / bad token — prune it so we stop trying.
      await admin.from("device_tokens").delete().eq("token", token);
    }
  }

  return json({ delivered });
});

function buildMessage(type: string, handle: string, comment: string): { title: string; message: string } {
  switch (type) {
    case "like":            return { title: "New like", message: `${handle} liked your session` };
    case "comment":         return { title: "New comment", message: `${handle} commented: ${comment}` };
    case "follow":          return { title: "New follower", message: `${handle} started following you` };
    case "tag":             return { title: "You were tagged", message: `${handle} tagged you in a session` };
    case "repost_approved": return { title: "Repost approved", message: `${handle} approved your repost` };
    default:                return { title: "pickleball.ai", message: `${handle} interacted with your post` };
  }
}

// --- APNs JWT (ES256) via WebCrypto ---

let cachedToken: { jwt: string; iat: number } | null = null;

async function apnsJWT(): Promise<string> {
  // APNs tokens are valid up to 1h; refresh well inside that window.
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.iat < 50 * 60) return cachedToken.jwt;

  const keyId = mustEnv("APNS_KEY_ID");
  const teamId = mustEnv("APNS_TEAM_ID");
  const key = await importP8(mustEnv("APNS_KEY"));

  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: now }));
  const signingInput = `${header}.${claims}`;
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  const jwt = `${signingInput}.${b64url(new Uint8Array(sig))}`;
  cachedToken = { jwt, iat: now };
  return jwt;
}

async function importP8(pem: string): Promise<CryptoKey> {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    der.buffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

function b64url(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function mustEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing env ${name}`);
  return v;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
