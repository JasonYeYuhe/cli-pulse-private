package com.clipulse.android.data.model

/**
 * v1.27 E2 — Android mirror of the iOS `DeviceRecord` managed-session
 * capability extension (Models.swift). Pure functions over [DeviceRecord]
 * so the managed-sessions start picker can version-gate providers without
 * any Android/Compose dependency (and so the logic is unit-testable in
 * isolation, mirroring `DeviceRecord+supportsManagedSessionProvider` on iOS).
 *
 * Remote managed-session support is version-gated because paired Macs
 * before helper 1.15 only know how to spawn Claude. Sending Codex/Gemini
 * start commands to those helpers creates pending cloud rows that can never
 * become running.
 */

/** True when [provider] can be spawned as a managed session on this Mac. */
fun DeviceRecord.supportsManagedSessionProvider(provider: String): Boolean =
    when (provider.trim().lowercase()) {
        // Claude managed sessions work on any helper that reports a version.
        "claude" -> helperVersion.isNotBlank()
        // Multi-CLI (Codex / Gemini) managed sessions need helper 1.15+.
        "codex", "gemini" -> helperVersionAtLeast(1, 15, 0)
        else -> false
    }

/** True when this Mac's helper can spawn Codex/Gemini (1.15+), not just Claude. */
val DeviceRecord.supportsMultiCLIManagedSessions: Boolean
    get() = helperVersionAtLeast(1, 15, 0)

/**
 * Semver-aware comparison mirroring the iOS `helperVersionAtLeast`: parse
 * the first `major.minor[.patch]` token out of the (possibly decorated)
 * helper version string and compare against the required floor.
 */
fun DeviceRecord.helperVersionAtLeast(major: Int, minor: Int, patch: Int): Boolean {
    val version = firstSemanticVersion(helperVersion) ?: return false
    if (version.first != major) return version.first > major
    if (version.second != minor) return version.second > minor
    return version.third >= patch
}

/**
 * Extract the first `(\d+).(\d+)[.(\d+)]` triple from [raw], defaulting an
 * absent patch component to 0. Returns null when no version-like token is
 * present (e.g. an empty helper_version on an unpaired/legacy device).
 * Matches the iOS `firstSemanticVersion(in:)` NSRegularExpression.
 */
internal fun firstSemanticVersion(raw: String): Triple<Int, Int, Int>? {
    val match = SEMVER_REGEX.find(raw) ?: return null
    val major = match.groupValues[1].toIntOrNull() ?: return null
    val minor = match.groupValues[2].toIntOrNull() ?: return null
    val patch = match.groupValues.getOrNull(3)?.toIntOrNull() ?: 0
    return Triple(major, minor, patch)
}

private val SEMVER_REGEX = Regex("""(\d+)\.(\d+)(?:\.(\d+))?""")

/**
 * The Mac this app would target when the user asks to start a managed
 * session — the most-recently-synced paired Mac that has the helper
 * installed. Mirrors the iOS `iOSSessionsTab.targetDeviceForStart`
 * computed property (Mac type + non-empty helper_version + newest
 * last_sync_at first). Null when no eligible Mac is paired.
 */
fun List<DeviceRecord>.managedSessionTargetDevice(): DeviceRecord? =
    this
        .filter { it.type.equals("Mac", ignoreCase = true) }
        .filter { it.helperVersion.isNotBlank() }
        .sortedByDescending { it.lastSyncAt ?: "" }
        .firstOrNull()
