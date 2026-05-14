package com.clipulse.android.ui.permission

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import com.clipulse.android.R

// v1.20.1 C7: Android 13+ (API 33) requires runtime POST_NOTIFICATIONS grant.
// The permission is declared in AndroidManifest.xml but was never requested,
// so every fresh install on Android 13/14/15 received zero push notifications
// silently — remote approval / quota alerts simply never arrived.
//
// We ask once per install on first login. If the user declines or dismisses,
// we don't nag — they can re-enable from system Settings → Apps → CLI Pulse.

private const val PREFS_NAME = "clipulse.permissions"
private const val KEY_ASKED = "notifications_asked"

@Composable
fun NotificationPermissionEffect() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return

    val context = LocalContext.current
    val prefs = remember(context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }
    var showRationale by remember { mutableStateOf(false) }

    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { _ ->
        // We don't react to grant/deny — the user's decision is final;
        // Android shows its own follow-up if they need to revisit it.
    }

    LaunchedEffect(Unit) {
        val asked = prefs.getBoolean(KEY_ASKED, false)
        if (asked) return@LaunchedEffect
        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            showRationale = true
        } else {
            // Already granted (e.g. user already toggled on in Settings).
            // Record as asked so we don't second-guess later.
            prefs.edit().putBoolean(KEY_ASKED, true).apply()
        }
    }

    if (showRationale) {
        val markAsked: () -> Unit = {
            prefs.edit().putBoolean(KEY_ASKED, true).apply()
            showRationale = false
        }
        AlertDialog(
            onDismissRequest = markAsked,
            title = { Text(stringResource(R.string.notification_permission_title)) },
            text = { Text(stringResource(R.string.notification_permission_body)) },
            confirmButton = {
                TextButton(onClick = {
                    markAsked()
                    launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
                }) { Text(stringResource(R.string.notification_permission_continue)) }
            },
            dismissButton = {
                TextButton(onClick = markAsked) {
                    Text(stringResource(R.string.notification_permission_not_now))
                }
            },
        )
    }
}
