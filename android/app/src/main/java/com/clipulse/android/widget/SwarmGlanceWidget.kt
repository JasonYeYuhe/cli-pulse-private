package com.clipulse.android.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.provideContent
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.clipulse.android.data.repository.DashboardRepository
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

/**
 * v1.22 P0 S5 — Android home-screen "Swarm at-a-glance" Glance widget.
 *
 * Renders `{n agents · m blocked}` (NO `$` — R2-5; opaque handle, no
 * repo/branch — RK7). Greenfield (the app's first Glance widget) — kept
 * deliberately minimal per the plan's "at-a-glance" scope: a stacked
 * text column, no custom layout helpers. Refreshes on the system
 * widget cadence; the RPC is RC-gated server-side so it shows "No
 * active swarms" until Remote Control is on.
 */
class SwarmGlanceWidget : GlanceAppWidget() {

    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface SwarmWidgetEntryPoint {
        fun dashboardRepository(): DashboardRepository
    }

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val repo = EntryPointAccessors
            .fromApplication(context, SwarmWidgetEntryPoint::class.java)
            .dashboardRepository()

        // Best-effort live pull; RC-off / network error → last/empty.
        // Never throw out of provideGlance.
        runCatching { repo.refreshSwarms() }
        val devices = repo.swarms.value
        val live = devices.filter { !it.stale }.flatMap { it.swarms }
        val agents = live.sumOf { it.agents }
        val blocked = live.sumOf { it.blocked }
        val swarms = devices.sumOf { it.swarms.size }

        provideContent {
            SwarmWidgetContent(agents = agents, blocked = blocked, swarms = swarms)
        }
    }
}

private val Ink = ColorProvider(Color(0xFFE6E6E6))
private val Dim = ColorProvider(Color(0xFF9A9A9A))
private val Warn = ColorProvider(Color(0xFFFF9F0A))

@Composable
private fun SwarmWidgetContent(agents: Int, blocked: Int, swarms: Int) {
    Column(
        modifier = GlanceModifier.fillMaxSize().padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalAlignment = Alignment.Start,
    ) {
        Text(
            text = "Swarm",
            style = TextStyle(color = Dim, fontWeight = FontWeight.Medium, fontSize = 12.sp),
        )
        if (agents == 0) {
            Text(
                text = "No active swarms",
                style = TextStyle(color = Dim, fontSize = 13.sp),
            )
        } else {
            Text(
                text = "$agents agents",
                style = TextStyle(color = Ink, fontWeight = FontWeight.Bold, fontSize = 20.sp),
            )
            if (blocked > 0) {
                Text(
                    text = "$blocked blocked",
                    style = TextStyle(color = Warn, fontWeight = FontWeight.Bold, fontSize = 14.sp),
                )
            }
            Text(
                text = if (swarms == 1) "1 swarm" else "$swarms swarms",
                style = TextStyle(color = Dim, fontSize = 11.sp),
            )
        }
    }
}

/** System-driven receiver (cadence set in swarm_glance_widget_info.xml). */
class SwarmGlanceReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = SwarmGlanceWidget()
}
