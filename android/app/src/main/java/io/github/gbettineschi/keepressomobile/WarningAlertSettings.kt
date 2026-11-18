package io.github.gbettineschi.keepressomobile

import android.app.NotificationManager
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

@Composable fun WarningAlertSettings() {
    val context=LocalContext.current
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    var revision by remember { mutableIntStateOf(0) }
    DisposableEffect(lifecycle) {
        val observer=LifecycleEventObserver { _,event -> if(event==Lifecycle.Event.ON_RESUME){Notifications.channels(context);CriticalWarningSound.ensure(context);revision++} }
        lifecycle.addObserver(observer);onDispose{lifecycle.removeObserver(observer)}
    }
    val manager=context.getSystemService(NotificationManager::class.java)
    val audio=context.getSystemService(AudioManager::class.java)
    val channel=remember(revision){Notifications.channels(context);CriticalWarningSound.ensure(context);manager.getNotificationChannel(CriticalWarningSound.CHANNEL)}
    val enabled=manager.areNotificationsEnabled() && channel.importance>NotificationManager.IMPORTANCE_NONE
    val muted=audio.getStreamVolume(AudioManager.STREAM_ALARM)==0
    Text("Heat and sleep warnings stay on when routine reminders are snoozed.",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
    Text(when{!enabled->"Notifications are off";muted->"Alarm volume is muted";channel.sound==null->"Warning sound is off";!channel.shouldVibrate()->"Vibration is off";else->"Sound and vibration enabled"},style=MaterialTheme.typography.bodyMedium)
    Text(if(channel.canBypassDnd())"Do Not Disturb exception enabled" else "Do Not Disturb may silence warnings",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
    Text("Sound follows alarm volume and Android’s Do Not Disturb rules.",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
    TextButton(onClick={context.startActivity(Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,context.packageName).putExtra(Settings.EXTRA_CHANNEL_ID,CriticalWarningSound.CHANNEL))}){Text("Android alert settings")}
    if (Build.VERSION.SDK_INT >= 34 && !manager.canUseFullScreenIntent()) {
        TextButton(onClick = {
            runCatching { context.startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.fromParts("package", context.packageName, null))) }
        }) { Text("Full-screen alarm settings") }
    }
    if(!channel.canBypassDnd()) TextButton(onClick={context.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))}){Text("Allow during Do Not Disturb")}
    val exact = remember(revision) { CriticalAlarmReceiver.exactAllowed(context) }
    Text(if (exact) "Critical Ignore can rearm after five minutes" else "Android may delay the alarm after Ignore", style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
    if (!exact && Build.VERSION.SDK_INT >= 31) TextButton(onClick = {
        runCatching { context.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.fromParts("package", context.packageName, null))) }
    }) { Text("Allow precise alarm timing") }
    if(muted) TextButton(onClick={context.startActivity(Intent(Settings.ACTION_SOUND_SETTINGS))}){Text("Sound settings")}
    TextButton(onClick={CriticalWarningSound.preview(context)},enabled=enabled){Text("Test alert")}
}
