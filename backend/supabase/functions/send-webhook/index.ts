// Supabase Edge Function: send-webhook
// Sends alert notifications to user-configured webhook URLs.
// Auto-detects Discord vs Slack webhook format.
//
// Request:
//   { "user_id": "uuid", "alert": { "type", "severity", "title", "message", "related_provider?" } }
//
// Features:
//   - Slack Block Kit format for hooks.slack.com URLs
//   - Discord embed format for discord.com/api/webhooks URLs
//   - Event filtering via user_settings.webhook_event_filter (JSON)
//   - SSRF protection (HTTPS only; literal-IP + DNS-resolved private/loopback
//     blocking; redirect:"manual"; never echoes upstream body) — see ssrf.ts
//   - 60-second deduplication per alert grouping_key

// v1.9.7 P1-4: use built-in Deno.serve instead of the legacy
// `deno.land/std@0.177.0/http/server.ts` import.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { resolveAndCheckHost, validateWebhookUrlShape } from "./ssrf.ts";

const DEDUP_WINDOW_MS = 60_000;
const MAX_BODY_BYTES = 102400;

/** Read a request body with a hard byte cap. NEW-L21: content-length is absent
 *  on chunked requests, so the header check alone is bypassable — enforce on
 *  the bytes actually read. */
async function readBodyCapped(req: Request, max: number): Promise<string> {
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      try { await reader.cancel(); } catch (_e) { /* ignore */ }
      throw new Error("body too large");
    }
    chunks.push(value);
  }
  const buf = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { buf.set(c, off); off += c.byteLength; }
  return new TextDecoder().decode(buf);
}

const SEVERITY_COLORS: Record<string, number> = {
  Critical: 0xff0000,
  Warning: 0xffa500,
  Info: 0x3498db,
};

const SEVERITY_EMOJI: Record<string, string> = {
  Critical: "\u{1F6A8}",
  Warning: "\u26A0\uFE0F",
  Info: "\u2139\uFE0F",
};

function isSlackUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.hostname === "hooks.slack.com";
  } catch {
    return false;
  }
}

interface WebhookEventFilter {
  severities?: string[];   // e.g. ["Critical", "Warning"]
  types?: string[];        // e.g. ["cost_spike", "quota_exceeded"]
  providers?: string[];    // e.g. ["Claude", "OpenRouter"]
}

// UI offers four slugs (cost_spike|quota_exceeded|session_long|device_offline).
// Real alert.type strings emitted by AlertGenerator.swift, app_rpc.sql, and
// Models.swift are human-readable (e.g. "Cost Spike", "Helper Offline"). Direct
// `includes` comparison silently dropped every alert when any filter was set.
// Map slugs → emitted types. "Usage Spike" piggybacks on the cost_spike chip
// because the UI has no dedicated chip for device-CPU spikes.
//
// Drift guard: backend/supabase/ci_check_alert_types.py asserts every emitted
// type appears here; CI fails if a new generator type slips in unmapped.
const TYPE_ALIASES: Record<string, string[]> = {
  cost_spike: ["Cost Spike", "Project Budget Exceeded", "Usage Spike"],
  quota_exceeded: ["Quota Warning"],
  session_long: ["Session Too Long"],
  device_offline: ["Helper Offline"],
};

function shouldSendAlert(
  alert: { type?: string; severity?: string; related_provider?: string },
  filter: WebhookEventFilter | null,
): boolean {
  if (!filter) return true;
  if (filter.severities?.length && !filter.severities.includes(alert.severity || "Info")) {
    return false;
  }
  if (filter.types?.length) {
    const t = alert.type || "";
    const matched = filter.types.some((slug) =>
      (TYPE_ALIASES[slug] ?? [slug]).includes(t)
    );
    if (!matched) return false;
  }
  if (filter.providers?.length && alert.related_provider && !filter.providers.includes(alert.related_provider)) {
    return false;
  }
  return true;
}

function buildSlackPayload(alert: {
  type?: string;
  severity?: string;
  title?: string;
  message?: string;
  related_provider?: string;
}): Record<string, unknown> {
  const emoji = SEVERITY_EMOJI[alert.severity || "Info"] || "\u2139\uFE0F";
  const blocks: Record<string, unknown>[] = [
    {
      type: "header",
      text: { type: "plain_text", text: `${emoji} CLI Pulse: ${alert.severity || "Info"}`, emoji: true },
    },
    {
      type: "section",
      text: { type: "mrkdwn", text: `*${alert.title || "Alert"}*` },
    },
  ];

  const fields: { type: string; text: string }[] = [];
  if (alert.type) fields.push({ type: "mrkdwn", text: `*Type:* ${alert.type}` });
  if (alert.severity) fields.push({ type: "mrkdwn", text: `*Severity:* ${alert.severity}` });
  if (alert.related_provider) fields.push({ type: "mrkdwn", text: `*Provider:* ${alert.related_provider}` });

  if (fields.length > 0) {
    blocks.push({ type: "section", fields });
  }

  if (alert.message) {
    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: alert.message.substring(0, 3000) },
    });
  }

  blocks.push({
    type: "context",
    elements: [
      { type: "mrkdwn", text: `CLI Pulse \u2022 ${new Date().toISOString()}` },
    ],
  });

  return { blocks };
}

function buildDiscordPayload(alert: {
  type?: string;
  severity?: string;
  title?: string;
  message?: string;
  related_provider?: string;
}): Record<string, unknown> {
  const color = SEVERITY_COLORS[alert.severity || "Info"] || 0x95a5a6;
  const fields: { name: string; value: string; inline: boolean }[] = [
    { name: "Type", value: alert.type || "Alert", inline: true },
    { name: "Severity", value: alert.severity || "Info", inline: true },
  ];
  if (alert.message) {
    fields.push({ name: "Details", value: alert.message.substring(0, 1024), inline: false });
  }
  if (alert.related_provider) {
    fields.push({ name: "Provider", value: alert.related_provider, inline: true });
  }

  // Iter2 follow-up (Gemini): the Discord webhook API rejects payloads
  // with `content: null` ("This field must be of type string"). When we
  // only ship embeds and no text content, the `content` key must be
  // OMITTED, not present-as-null.
  return {
    embeds: [
      {
        title: `CLI Pulse: ${alert.severity || "Info"}`,
        description: alert.title || "Alert",
        color,
        fields,
        footer: { text: "CLI Pulse Alert" },
        timestamp: new Date().toISOString(),
      },
    ],
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type" },
    });
  }

  try {
    const authHeader = req.headers.get("authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing authorization header" }), { status: 401 });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // ── Auth path selection ──
    // Two callers exist:
    //   1. The DB cron worker `process_webhook_jobs` POSTs with a service-role
    //      bearer + `X-Internal-Trigger: alerts_dispatch_webhook` header. The
    //      `user_id` in the body is authoritative because it came from the
    //      INSERT-trigger row.
    //   2. End-user clients POST with a user JWT (e.g. the test-webhook
    //      button in Settings). We verify the JWT and require user_id match.
    //
    // CRITICAL: the X-Internal-Trigger header alone is NOT auth. We MUST
    // verify the bearer is the service-role key before trusting the body's
    // user_id; otherwise anyone could impersonate the trigger.
    const internalTrigger = req.headers.get("x-internal-trigger");
    const isInternalTrigger =
      internalTrigger === "alerts_dispatch_webhook" &&
      authHeader === "Bearer " + supabaseServiceKey;

    let user_id_authoritative: string;

    if (internalTrigger === "alerts_dispatch_webhook" && !isInternalTrigger) {
      // Header set without the matching bearer — refuse.
      return new Response(
        JSON.stringify({ error: "Forbidden: internal trigger requires service role bearer" }),
        { status: 403 },
      );
    }

    if (!isInternalTrigger) {
      // Client path: verify JWT.
      const userClient = createClient(supabaseUrl, supabaseAnonKey, {
        global: { headers: { Authorization: authHeader } },
      });
      const { data: { user }, error: userError } = await userClient.auth.getUser();
      if (userError || !user) {
        return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
      }
      user_id_authoritative = user.id;
    }

    // ── Request size guard (NEW-L21) ──
    const contentLength = req.headers.get("content-length");
    if (contentLength && parseInt(contentLength) > MAX_BODY_BYTES) {
      return new Response(JSON.stringify({ error: "Request too large" }), { status: 413 });
    }
    // deno-lint-ignore no-explicit-any
    let body: any;
    try {
      const raw = await readBodyCapped(req, MAX_BODY_BYTES);
      body = JSON.parse(raw);
    } catch {
      return new Response(JSON.stringify({ error: "Invalid or oversized request body" }), { status: 400 });
    }
    const { user_id, alert } = body;
    if (!user_id || !alert) {
      return new Response(JSON.stringify({ error: "Missing user_id or alert" }), { status: 400 });
    }

    if (isInternalTrigger) {
      user_id_authoritative = user_id;
    } else if (user_id !== user_id_authoritative!) {
      return new Response(JSON.stringify({ error: "Forbidden: user_id mismatch" }), { status: 403 });
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // ── Dedup (rollout-window protection) ──
    // For client-path callers (old macOS apps still doing inline
    // webhook fan-out), probe `webhook_jobs` for a row covering the
    // same (user_id, grouping_key) within the last DEDUP_WINDOW_MS.
    // If present, the server-side trigger has already enqueued the
    // same alert; skip to avoid double-fire.
    //
    // Internal-trigger callers come from process_webhook_jobs which
    // dispatches AT MOST ONE pg_net request per webhook_jobs row, so
    // they don't need this probe.
    if (!isInternalTrigger) {
      const groupingKey = alert.grouping_key || alert.type || "";
      if (groupingKey) {
        const { data: existingJob } = await supabase
          .from("webhook_jobs")
          .select("id")
          .eq("user_id", user_id_authoritative!)
          .filter("alert_payload->>grouping_key", "eq", groupingKey)
          .gte("enqueued_at", new Date(Date.now() - DEDUP_WINDOW_MS).toISOString())
          .limit(1)
          .maybeSingle();
        if (existingJob) {
          return new Response(
            JSON.stringify({ skipped: true, reason: "dedup (server trigger already enqueued)" }),
            { status: 200 },
          );
        }
      }
    }

    const { data: settings, error: fetchError } = await supabase
      .from("user_settings")
      .select("webhook_url, webhook_enabled, webhook_event_filter")
      .eq("user_id", user_id_authoritative!)
      .single();

    if (fetchError || !settings?.webhook_enabled || !settings?.webhook_url) {
      return new Response(JSON.stringify({ skipped: true, reason: "webhook not configured" }), { status: 200 });
    }

    // Apply event filter (if configured)
    const eventFilter: WebhookEventFilter | null = settings.webhook_event_filter || null;
    if (!shouldSendAlert(alert, eventFilter)) {
      return new Response(JSON.stringify({ skipped: true, reason: "filtered" }), { status: 200 });
    }

    // Validate URL (NEW-H3): HTTPS + literal-IP block (sync), then resolve the
    // hostname and reject if it points at a private/internal address.
    const shape = validateWebhookUrlShape(settings.webhook_url);
    if (!shape.valid) {
      return new Response(JSON.stringify({ error: shape.error }), { status: 400 });
    }
    if (shape.host?.kind === "dns-name") {
      const dns = await resolveAndCheckHost(shape.host.host);
      if (!dns.ok) {
        return new Response(JSON.stringify({ error: dns.error }), { status: 400 });
      }
    }

    // Build payload — auto-detect Slack vs Discord format
    const payload = isSlackUrl(settings.webhook_url)
      ? buildSlackPayload(alert)
      : buildDiscordPayload(alert);

    // Send webhook (5s timeout to prevent tarpit attacks).
    // NEW-H3: redirect:"manual" so a 3xx to an internal host is NOT followed.
    const webhookResp = await fetch(settings.webhook_url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      redirect: "manual",
      signal: AbortSignal.timeout(5000),
    });

    // A redirect (opaqueredirect under manual mode, or a 3xx) is refused — we
    // never chase the Location, which could resolve to an internal address.
    if (webhookResp.type === "opaqueredirect" ||
        (webhookResp.status >= 300 && webhookResp.status < 400)) {
      return new Response(JSON.stringify({ sent: false, reason: "redirect refused" }), { status: 502 });
    }

    if (!webhookResp.ok) {
      // NEW-M3: never echo the upstream response body — that turns the SSRF
      // surface into a read primitive. Return only the status code.
      return new Response(JSON.stringify({ sent: false, status: webhookResp.status }), { status: 502 });
    }

    return new Response(JSON.stringify({ sent: true }), { status: 200 });
  } catch (_err) {
    // NEW-M3: do not leak raw error text (may carry host/URL fragments).
    return new Response(JSON.stringify({ error: "Internal error" }), { status: 500 });
  }
});
