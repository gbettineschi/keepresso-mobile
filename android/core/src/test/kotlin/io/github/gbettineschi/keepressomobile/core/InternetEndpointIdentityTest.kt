package io.github.gbettineschi.keepressomobile.core

import org.junit.Assert.*
import org.junit.Test

class InternetEndpointIdentityTest {
    @Test fun reconnectAndRestartReuseThePrivatelySavedIdentity() {
        var saved:String?=null;var writes=0
        fun store()=InternetEndpointIdentity({saved},{saved=it;writes++})
        val first=store().loadOrCreate()
        assertEquals(32,first.size)
        assertArrayEquals(first,store().loadOrCreate())
        assertArrayEquals(first,store().loadOrCreate())
        assertEquals(1,writes)
    }
    @Test fun malformedExistingIdentityIsNotReplaced() {
        for(bad in listOf("{}","{\"version\":2,\"seed\":\"bad\"}","{\"version\":1,\"seed\":\"bad\"}")) {
            var writes=0
            assertTrue(runCatching{InternetEndpointIdentity({bad},{writes++}).loadOrCreate()}.isFailure)
            assertEquals(0,writes)
        }
    }
}
