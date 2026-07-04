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
    // v0.63 (System Monitor): machine-health sensors synced from this device's
    // helper heartbeat. All nullable (null = not reported / not supported). The
    // phone renders a read-only summary; sensorsCapability is the honest per-device
    // map so it never claims a reading it doesn't have.
    val cpuTempC: Double? = null,
    val gpuTempC: Double? = null,
    val cpuPowerW: Double? = null,
    val systemPowerW: Double? = null,
    val fanRpm: Int? = null,
    val fanMaxRpm: Int? = null,
    val thermalState: Int? = null,
    val batteryChargePct: Int? = null,
    val batteryState: String? = null,
    val batteryCycleCount: Int? = null,
    val batteryHealthPct: Double? = null,
    val adapterWatts: Double? = null,
    val sensorsCapability: Map<String, Boolean> = emptyMap(),
    val sensorsUpdatedAt: String? = null,
) {
    val deviceStatus: DeviceStatus? get() = DeviceStatus.fromString(status)

    /** True when this device reported any machine-health sensors — the phone
     *  shows the device-health section only for these. */
    val hasDeviceHealth: Boolean
        get() = sensorsUpdatedAt != null || sensorsCapability.isNotEmpty() ||
            cpuTempC != null || fanRpm != null || batteryHealthPct != null

    /** Honest capability check (a fanless Air has no fans, a Mac mini no battery). */
    fun sensorCan(key: String): Boolean = sensorsCapability[key] == true

    /** True when a managed session for [provider] on this device would run
     *  OFF-plan (billed via the provider's API) rather than the user's plan —
     *  mirrors the macOS/iOS picker warning. Absent/unknown/on_plan => false. */
    fun isProviderOffPlan(provider: String): Boolean =
        providerPlanStatus[provider] == "off_plan"
}
