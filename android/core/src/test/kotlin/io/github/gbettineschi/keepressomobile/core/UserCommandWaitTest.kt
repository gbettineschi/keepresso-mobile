package io.github.gbettineschi.keepressomobile.core
import kotlin.test.*

class UserCommandWaitTest {
    @Test fun tapDuringReadWaitsOnceAndRepeatedTapDoesNotDuplicateIt(){
        val wait=UserCommandWait()
        assertTrue(wait.offer(WaitingCommand("start_manual",150),100,"nearby:1"))
        assertFalse(wait.offer(WaitingCommand("start_manual",150),101,"nearby:1"))
        assertEquals(WaitingCommand("start_manual",150),wait.take(200,"nearby:1",true))
        assertNull(wait.take(201,"nearby:1",true))
    }
    @Test fun expiredDisconnectedOrStaleCommandCannotRunAfterReconnect(){
        for((now,route,fresh) in listOf(Triple(8100L,"nearby:1",true),Triple(200L,"nearby:2",true),Triple(200L,"nearby:1",false))){
            val wait=UserCommandWait();wait.offer(WaitingCommand("sleep_now"),100,"nearby:1")
            assertNull(wait.take(now,route,fresh));assertNull(wait.take(201,"nearby:1",true))
        }
    }
    @Test fun leavingForegroundDropsUnsubmittedActionAndDeadlineDoesNotExtend(){
        val wait=UserCommandWait();wait.offer(WaitingCommand("stop_manual"),0,"relay:epoch")
        assertFalse(wait.expire(7999));assertTrue(wait.expire(8000));assertFalse(wait.hasCommand)
        wait.offer(WaitingCommand("stop_manual"),9000,"relay:epoch");assertTrue(wait.clear())
        assertNull(wait.take(9001,"relay:epoch",true))
    }
}
