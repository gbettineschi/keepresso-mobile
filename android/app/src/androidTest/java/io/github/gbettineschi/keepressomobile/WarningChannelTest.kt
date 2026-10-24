package io.github.gbettineschi.keepressomobile
import android.app.NotificationManager
import android.media.AudioAttributes
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.*

class WarningChannelTest {
    @get:Rule val emulator=EmulatorOnlyRule()
    @Test fun urgentWarningsUseAlarmAudioAndVibrationWithoutGrantingDndAccess(){
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val manager=context.getSystemService(NotificationManager::class.java)
        val accessBefore=manager.isNotificationPolicyAccessGranted
        Notifications.channels(context)
        val channel=manager.getNotificationChannel("urgent_warnings_v1")
        Assert.assertNotNull("The urgent warning category must be created",channel)
        Assert.assertEquals(NotificationManager.IMPORTANCE_HIGH,channel.importance)
        Assert.assertEquals(AudioAttributes.USAGE_ALARM,channel.audioAttributes.usage)
        Assert.assertNotNull(channel.sound);Assert.assertTrue(channel.shouldVibrate())
        Assert.assertEquals(accessBefore,manager.isNotificationPolicyAccessGranted)
        if(!accessBefore)Assert.assertFalse(channel.canBypassDnd())
    }
}
