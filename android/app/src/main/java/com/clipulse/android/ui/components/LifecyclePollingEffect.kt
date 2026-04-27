package com.clipulse.android.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver

/**
 * Iter2 (Change 9): centralised lifecycle-aware polling toggle.
 *
 * Each tab's ViewModel runs a `while(true) { delay(30_000) }` polling loop
 * gated by an internal `_isPolling: MutableStateFlow<Boolean>`. This effect
 * flips the ViewModel's polling flag in lockstep with the host Composable's
 * lifecycle: ON_START → poll, ON_STOP → idle, so a backgrounded app does
 * not burn battery hammering Supabase every 30s.
 *
 * Usage at the top of each tab Composable:
 *
 *     @Composable
 *     fun SessionsScreen(viewModel: SessionsViewModel = hiltViewModel()) {
 *         LifecyclePollingEffect(viewModel::setPolling)
 *         // …
 *     }
 *
 * Why a function reference instead of a generic ViewModel constraint:
 * keeping the ViewModels independent (no shared base class) costs one
 * extra line per call site but avoids dragging an inheritance hierarchy
 * across Sessions/Alerts/Overview/Providers/Devices. The five
 * `setPolling(Boolean)` methods have identical signatures by convention
 * (enforced via the `Iter2 Change 9` comment in each ViewModel — there
 * is no compile-time interface).
 */
@Composable
fun LifecyclePollingEffect(setPolling: (Boolean) -> Unit) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> setPolling(true)
                Lifecycle.Event.ON_STOP -> setPolling(false)
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
}
