// Sends an email whenever someone joins the waitlist. Invoked server-to-server
// by the on_waitlist_insert_notify trigger (pg_net), never by a client.
//
// Required secrets (supabase secrets set ...):
//   WAITLIST_FUNCTION_SECRET  shared bearer that must match the DB's waitlist_function_key
//   RESEND_API_KEY            Resend API key (re_...) for sending the email
//   WAITLIST_NOTIFY_TO        destination address (e.g. drewmanley16@gmail.com)
//   WAITLIST_NOTIFY_FROM      optional sender (default: piclr <onboarding@resend.dev>)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type WaitlistRow = {
  id: string;
  email: string;
  created_at: string;
};

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

    const secret = Deno.env.get("WAITLIST_FUNCTION_SECRET");
    const auth = req.headers.get("Authorization") ?? "";
    if (!secret || auth !== `Bearer ${secret}`) {
      return json({ error: "Unauthorized" }, 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const resendKey = Deno.env.get("RESEND_API_KEY");
    const to = Deno.env.get("WAITLIST_NOTIFY_TO");
    const from = Deno.env.get("WAITLIST_NOTIFY_FROM") ?? "piclr <onboarding@resend.dev>";
    if (!supabaseUrl || !serviceRoleKey) return json({ error: "Not configured (supabase)" }, 500);
    if (!resendKey || !to) return json({ error: "Not configured (resend)" }, 500);

    const body = await req.json().catch(() => null);
    const waitlistId = body?.waitlist_id;
    if (!waitlistId) return json({ error: "waitlist_id required" }, 400);

    // Load the signup row (service role — bypasses RLS).
    const admin = createClient(supabaseUrl, serviceRoleKey);
    const { data: row, error: rowErr } = await admin
      .from("waitlist")
      .select("id, email, created_at")
      .eq("id", waitlistId)
      .single<WaitlistRow>();
    if (rowErr || !row) return json({ error: "Waitlist row not found" }, 404);

    // Total signups so far, for a bit of context in the email.
    const { count } = await admin
      .from("waitlist")
      .select("id", { count: "exact", head: true });

    const joinedAt = new Date(row.created_at).toLocaleString("en-US", {
      timeZone: "America/New_York",
      dateStyle: "medium",
      timeStyle: "short",
    });
    const total = typeof count === "number" ? count : null;

    const subject = `New piclr waitlist signup: ${row.email}`;
    const html = `
      <div style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;font-size:15px;color:#111;">
        <p style="margin:0 0 12px;">Someone just joined the piclr waitlist.</p>
        <p style="margin:0 0 4px;"><strong>Email:</strong> ${escapeHtml(row.email)}</p>
        <p style="margin:0 0 4px;"><strong>Joined:</strong> ${escapeHtml(joinedAt)} ET</p>
        ${total !== null ? `<p style="margin:0 0 4px;"><strong>Total signups:</strong> ${total}</p>` : ""}
      </div>`;
    const text =
      `Someone just joined the piclr waitlist.\n\n` +
      `Email: ${row.email}\n` +
      `Joined: ${joinedAt} ET\n` +
      (total !== null ? `Total signups: ${total}\n` : "");

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${resendKey}`,
      },
      body: JSON.stringify({
        from,
        to: [to],
        reply_to: row.email,
        subject,
        html,
        text,
      }),
    });

    if (!res.ok) {
      const detail = await res.text();
      return json({ error: "Resend send failed", status: res.status, detail }, 502);
    }

    return json({ sent: true });
  } catch (err) {
    return json({ error: String(err) }, 500);
  }
});

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
