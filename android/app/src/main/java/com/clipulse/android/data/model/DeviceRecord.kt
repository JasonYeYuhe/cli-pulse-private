package com.clipulse.android.data.model

data class DeviceRecord(
    val id: String,
    val name: String,
    val type: String,
    val system: String,
    val status: String,
    val lastSyncAt: String? = null,
    val helperVersion: String,
    val currentSessionCount: Int,
    val cpuUsage: Int? = null,
    val memoryUsage: Int? = null,
    // v0.60: per-provider managed-session plan status ({"codex":"off_plan"}).
    // Values are "on_plan"/"off_plan"; a provider is ABSENT when unknown.
    val providerPlanStatus: Map<String, String> = emptyMap(),
) {
    val deviceStatus: DeviceStatus? get() = DeviceStatus.fromString(status)

    /** True when a managed session for [provider] on this device would run
     *  OFF-plan (billed via the provider's API) rather than the user's plan —
     *  mirrors the macOS/iOS picker warning. Absent/unknown/on_plan => false. */
    fun isProviderOffPlan(provider: String): Boolean =
        providerPlanStatus[provider] == "off_plan"
}
