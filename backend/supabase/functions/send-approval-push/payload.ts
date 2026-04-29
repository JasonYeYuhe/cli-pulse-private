// Pure payload builders for the send-approval-push edge function.
//
// Extracted into its own file so payload_test.ts can deno-test the
// shape WITHOUT the runtime APNs / Supabase deps. The privacy contract
// for these payloads is enforced here:
//
//   * APNs alert text is generic ("CLI Pulse approval needed" / "1 pending
//     remote approval"). It tells the user there is something to act on
//     and nothing else. No provider name, no tool, no path, no command.
//   * The only routing metadata is `request_id` (uuid). It carries no
//     content; the iOS app uses it after-the-fact to deep-link or refresh.
//   * No `user_id`, `device_id`, `device_name`, or any field derived from
//     redacted-but-still-sensitive helper input.
//
// Live APNs notification body strings can be localised by the iOS app via
// title-loc-key / loc-key in the future; for Phase 1 they are constants
// in English so a server-side payload_test can pin them.

/** APNs `alert` object — keep both fields minimal and content-free. */
export interface APNsAlert {
  title: string;
  body: string;
}

/** APNs top-level `aps` object. */
export interface APNsAps {
  alert: APNsAlert;
  category: string;
  "thread-id": string;
  sound: string;
}

/** Full JSON body that goes to api.push.apple.com:443. */
export interface APNsPayload {
  aps: APNsAps;
  request_id: string;
}

/** Banned substrings that MUST NOT appear anywhere in the JSON-stringified
 *  payload. payload_test.ts asserts this on every output of buildPushPayload.
 *  Names are lowercased for case-insensitive substring search. */
export const BANNED_PAYLOAD_SUBSTRINGS: readonly string[] = Object.freeze([
  // Helper-side fields.
  "tool_name",
  "tool_input",
  "summary",
  "command",
  "provider",
  "cwd",
  "cwd_basename",
  "cwd_hmac",
  "session_id",
  // App-side identity.
  "user_id",
  "device_id",
  "device_name",
  "helper_secret",
  // Sentinel for upstream redaction marker — if it ever leaks here we
  // know we accidentally embedded a redacted summary.
  "«redacted»",
]);

/**
 * Build the APNs JSON body for a "pending remote approval" notification.
 * The only identifying field is `request_id` so the iOS app can route
 * to the specific row after the user taps. Everything else is constant.
 */
export function buildPushPayload(requestId: string): APNsPayload {
  if (!requestId || typeof requestId !== "string") {
    throw new Error("buildPushPayload: requestId must be a non-empty string");
  }
  // request_id should look like a UUID; reject anything that contains
  // characters that could carry exfiltrated content. UUIDs are
  // [0-9a-fA-F-] only.
  if (!/^[0-9a-fA-F-]{1,64}$/.test(requestId)) {
    throw new Error("buildPushPayload: requestId is not a UUID-shape string");
  }
  return {
    aps: {
      alert: {
        title: "CLI Pulse approval needed",
        body: "1 pending remote approval",
      },
      category: "REMOTE_APPROVAL",
      "thread-id": "remote-approvals",
      sound: "default",
    },
    request_id: requestId,
  };
}

/**
 * Stringify a payload and check it doesn't contain any banned substring.
 * Used as a runtime defense-in-depth check before we ship the body to APNs.
 * If this throws, something is very wrong — abort the send.
 */
export function assertPayloadIsClean(payload: APNsPayload): void {
  const json = JSON.stringify(payload).toLowerCase();
  for (const banned of BANNED_PAYLOAD_SUBSTRINGS) {
    if (json.includes(banned.toLowerCase())) {
      throw new Error(
        `assertPayloadIsClean: payload leaked banned substring '${banned}'`,
      );
    }
  }
}
