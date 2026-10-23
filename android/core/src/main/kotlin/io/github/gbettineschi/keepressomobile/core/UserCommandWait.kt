package io.github.gbettineschi.keepressomobile.core

data class WaitingCommand(val action:String,val duration:Int?=null,val settings:ReminderSettings?=null)

/** Only unsent foreground intent waits behind a read. Never persists or replays. */
class UserCommandWait {
    private var command:WaitingCommand?=null
    private var route=""
    private var until=0L
    val hasCommand:Boolean get()=command!=null
    fun offer(value:WaitingCommand,nowMillis:Long,route:String):Boolean{
        if(command!=null)return false
        command=value;this.route=route;until=nowMillis+8000
        return true
    }
    fun take(nowMillis:Long,route:String,fresh:Boolean):WaitingCommand?{
        val result=command
        val valid=nowMillis<until && this.route==route && fresh
        clear()
        return result.takeIf{valid}
    }
    fun expire(nowMillis:Long):Boolean=if(command!=null && nowMillis>=until)clear() else false
    fun clear():Boolean{val existed=command!=null;command=null;route="";until=0;return existed}
}
