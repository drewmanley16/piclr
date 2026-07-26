// Sends an email whenever a user is reported (harassment, spam, abuse, etc).
// Invoked server-to-server by the on_report_insert_notify trigger (pg_net),
// never by a client. This is the "act on reports" mechanism required by
// Apple's UGC moderation guideline (1.2) — without it, reports landed in the
// `reports` table with no human ever seeing them.
//
// Required secrets (supabase secrets set ...):
//   REPORT_FUNCTION_SECRET  shared bearer that must match the DB's report_function_key
//   RESEND_API_KEY          Resend API key (re_...) for sending the email
//   REPORT_NOTIFY_TO        destination address (e.g. drewmanley16@gmail.com)
//   REPORT_NOTIFY_FROM      optional sender (default: piclr <onboarding@resend.dev>)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type ReportRow = {
  id: string;
  reporter_id: string;
  subject_user_id: string;
  target_type: string;
  target_id: string;
  reason: string;
  details: string | null;
  status: string;
  created_at: string;
  reporter: { username: string | null; display_name: string | null } | null;
  subject: { username: string | null; display_name: string | null } | null;
};

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

    const secret = Deno.env.get("REPORT_FUNCTION_SECRET");
    const auth = req.headers.get("Authorization") ?? "";
    if (!secret || auth !== `Bearer ${secret}`) {
      return json({ error: "Unauthorized" }, 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const resendKey = Deno.env.get("RESEND_API_KEY");
    const to = Deno.env.get("REPORT_NOTIFY_TO");
    const from = Deno.env.get("REPORT_NOTIFY_FROM") ?? "piclr <onboarding@resend.dev>";
    if (!supabaseUrl || !serviceRoleKey) return json({ error: "Not configured (supabase)" }, 500);
    if (!resendKey || !to) return json({ error: "Not configured (resend)" }, 500);

    const body = await req.json().catch(() => null);
    const reportId = body?.report_id;
    if (!reportId) return json({ error: "report_id required" }, 400);

    // Load the report row (service role — bypasses RLS) with reporter/subject
    // display names for a readable email.
    const admin = createClient(supabaseUrl, serviceRoleKey);
    const { data: row, error: rowErr } = await admin
      .from("reports")
      .select(
        "id, reporter_id, subject_user_id, target_type, target_id, reason, details, status, created_at," +
          "reporter:profiles!reports_reporter_id_fkey(username,display_name)," +
          "subject:profiles!reports_subject_user_id_fkey(username,display_name)"
      )
      .eq("id", reportId)
      .single<ReportRow>();
    if (rowErr || !row) return json({ error: "Report row not found" }, 404);

    // Open reports right now, for a bit of context/urgency in the email.
    const { count } = await admin
      .from("reports")
      .select("id", { count: "exact", head: true })
      .eq("status", "open");

    const filedAt = new Date(row.created_at).toLocaleString("en-US", {
      timeZone: "America/New_York",
      dateStyle: "medium",
      timeStyle: "short",
    });
    const openCount = typeof count === "number" ? count : null;
    const reporterLabel = row.reporter?.username ?? row.reporter?.display_name ?? row.reporter_id;
    const subjectLabel = row.subject?.username ?? row.subject?.display_name ?? row.subject_user_id;

    const subject = `piclr report: ${row.reason} (${row.target_type}) — @${subjectLabel}`;
    const html = `
      <div style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;font-size:15px;color:#111;">
        <p style="margin:0 0 12px;">A user was reported on piclr. Apple requires reports to be acted on within 24 hours.</p>
        <p style="margin:0 0 4px;"><strong>Reason:</strong> ${escapeHtml(row.reason)}</p>
        <p style="margin:0 0 4px;"><strong>Target:</strong> ${escapeHtml(row.target_type)} (${escapeHtml(row.target_id)})</p>
        <p style="margin:0 0 4px;"><strong>Reported user:</strong> @${escapeHtml(String(subjectLabel))} (${escapeHtml(row.subject_user_id)})</p>
        <p style="margin:0 0 4px;"><strong>Reported by:</strong> @${escapeHtml(String(reporterLabel))} (${escapeHtml(row.reporter_id)})</p>
        ${row.details ? `<p style="margin:0 0 4px;"><strong>Details:</strong> ${escapeHtml(row.details)}</p>` : ""}
        <p style="margin:0 0 4px;"><strong>Filed:</strong> ${escapeHtml(filedAt)} ET</p>
        ${openCount !== null ? `<p style="margin:0 0 4px;"><strong>Open reports:</strong> ${openCount}</p>` : ""}
        <p style="margin:12px 0 0;">Update the report's status in the reports table once reviewed.</p>
      </div>`;
    const text =
      `A user was reported on piclr. Apple requires reports to be acted on within 24 hours.\n\n` +
      `Reason: ${row.reason}\n` +
      `Target: ${row.target_type} (${row.target_id})\n` +
      `Reported user: @${subjectLabel} (${row.subject_user_id})\n` +
      `Reported by: @${reporterLabel} (${row.reporter_id})\n` +
      (row.details ? `Details: ${row.details}\n` : "") +
      `Filed: ${filedAt} ET\n` +
      (openCount !== null ? `Open reports: ${openCount}\n` : "");

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${resendKey}`,
      },
      body: JSON.stringify({
        from,
        to: [to],
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
