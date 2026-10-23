package io.github.gbettineschi.keepressomobile.core

import java.io.IOException
import kotlin.test.*

class PushRetryTest {
    @Test fun transientRegistrationFailuresRetryAtMostFiveAttempts() {
        for (attempt in 0..3) {
            assertTrue(PushRetry.retry(IOException("network unavailable"), attempt))
            assertTrue(PushRetry.retry(RelayHttpException(503), attempt))
        }
        assertFalse(PushRetry.retry(IOException("network unavailable"), 4))
        assertFalse(PushRetry.retry(RelayHttpException(503), 4))
    }
    @Test fun revokedInvalidAndMalformedRegistrationStopsImmediately() {
        for (status in listOf(400, 401, 403, 404, 409)) assertFalse(PushRetry.retry(RelayHttpException(status), 0))
        assertFalse(PushRetry.retry(IllegalArgumentException("invalid configuration"), 0))
    }
}
