// Receives RevenueCat webhook events and mirrors subscription state into
// public.entitlements (via the apply_revenuecat_event guard function), so
// server-side features can verify Pro without trusting the client. Invoked
// server-to-server by RevenueCat, never by the app.
//
// Required secrets (supabase secrets set ...):
//   REVENUECAT_WEBHOOK_SECRET  shared bearer; the RevenueCat dashboard webhook's
//                              Authorization header must be exactly "Bearer <secret>"
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.
//
// Response contract: 401 only on bad auth, 500 only on genuine failure (RevenueCat
// retries non-2xx with backoff — desirable for transient DB errors). Everything
// merely skippable (unknown event type, anonymous user, deleted account) returns
// 200 so RevenueCat doesn't retry forever.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Event types that update the entitlement row. Anything else is acknowledged
// and ignored (TEST, INVOICE_ISSUANCE, future types...).
const UPSERT_EVENTS = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "UNCANCELLATION",
  "CANCELLATION",
  "EXPIRATION",
  "BILLING_ISSUE",
  "PRODUCT_CHANGE",
  "NON_RENEWING_PURCHASE",
  "SUBSCRIPTION_EXTENDED",
]);

// Events after which the subscription will no longer auto-renew.
const NON_RENEWING = new Set(["CANCELLATION", "EXPIRATION", "BILLING_ISSUE", "NON_RENEWING_PURCHASE"]);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

type RCEvent = {
  type: string;
  app_user_id?: string;
  aliases?: string[];
  product_id?: string;
  period_type?: string;
  expiration_at_ms?: number | null;
  event_timestamp_ms?: number;
  environment?: string;
  transferred_from?: string[];
  entitlement_ids?: string[] | null;
};

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

    const secret = Deno.env.get("REVENUECAT_WEBHOOK_SECRET");
    const auth = req.headers.get("Authorization") ?? "";
    if (!secret || auth !== `Bearer ${secret}`) {
      return json({ error: "Unauthorized" }, 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) return json({ error: "Not configured" }, 500);

    const body = await req.json().catch(() => null);
    const event: RCEvent | undefined = body?.event;
    if (!event?.type) return json({ error: "event required" }, 400);

    const admin = createClient(supabaseUrl, serviceRoleKey);

    // A TRANSFER moves the subscription to another Apple account; expire the
    // losing users' rows. The gaining user's row arrives via its own events.
    if (event.type === "TRANSFER") {
      const losers = (event.transferred_from ?? [])
        .map(resolveUserId)
        .filter((id): id is string => id !== null);
      if (losers.length > 0) {
        const eventAt = new Date(event.event_timestamp_ms ?? 0).toISOString();
        // Same out-of-order guard as apply_revenuecat_event: a delayed TRANSFER
        // retry must not stomp a newer state (e.g. the user repurchased).
        const { error } = await admin
          .from("entitlements")
          .update({ status: "TRANSFER", will_renew: false, expires_at: eventAt, last_event_at: eventAt })
          .in("user_id", losers)
          .or(`last_event_at.is.null,last_event_at.lte.${eventAt}`);
        if (error) {
          console.error("revenuecat-webhook transfer update failed:", error);
          return json({ error: "db error" }, 500);
        }
      }
      return json({ transferred: losers.length });
    }

    if (!UPSERT_EVENTS.has(event.type)) return json({ ignored: event.type });

    // Only mirror events for the Pro entitlement — a future consumable or
    // second entitlement must not silently grant server-side Pro. Some event
    // types omit the field; treat missing as relevant rather than dropping.
    if (Array.isArray(event.entitlement_ids) && !event.entitlement_ids.includes("pro")) {
      return json({ skipped: "unrelated entitlement" });
    }

    const userId = resolveUserId(event.app_user_id) ??
      (event.aliases ?? []).map(resolveUserId).find((id) => id !== null) ?? null;
    if (!userId) return json({ skipped: "anonymous app_user_id" });

    const { data: applied, error } = await admin.rpc("apply_revenuecat_event", {
      p_user_id: userId,
      p_product_id: event.product_id ?? null,
      p_status: event.type,
      p_period_type: event.period_type ?? null,
      p_will_renew: !NON_RENEWING.has(event.type),
      p_expires_at: event.expiration_at_ms ? new Date(event.expiration_at_ms).toISOString() : null,
      p_environment: event.environment ?? null,
      p_event_at: new Date(event.event_timestamp_ms ?? Date.now()).toISOString(),
    });
    if (error) {
      // 23503: user no longer exists (account deleted) — acknowledge, don't retry.
      if (error.code === "23503") return json({ skipped: "user deleted" });
      console.error("revenuecat-webhook apply failed:", error);
      return json({ error: "db error" }, 500);
    }

    return json({ applied: applied === true });
  } catch (err) {
    console.error("revenuecat-webhook unhandled error:", err);
    return json({ error: "internal error" }, 500);
  }
});

// RevenueCat app_user_id → auth UUID, or null for anonymous/foreign ids. The
// app always logs in with the lowercased Supabase auth UUID.
function resolveUserId(appUserId: string | undefined | null): string | null {
  if (!appUserId) return null;
  const id = appUserId.toLowerCase();
  return UUID_RE.test(id) ? id : null;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
