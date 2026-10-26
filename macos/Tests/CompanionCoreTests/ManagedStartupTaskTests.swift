import Testing
@testable import CompanionCore
struct ManagedStartupTaskTests {
    @Test @MainActor func stopBeforeExecutionPreventsManagedStart()async{
        let owner=ManagedStartupTask();var effects=0,completions=0
        owner.start(operation:{effects+=1;return true},completion:{_ in completions+=1})
        owner.stop()
        for _ in 0..<10{await Task.yield()}
        #expect(effects==0);#expect(completions==0)
    }
    @Test @MainActor func stopCancelsInFlightWorkAndDiscardsItsCompletion()async{
        let owner=ManagedStartupTask();var release:CheckedContinuation<Bool,Never>?
        var effects=0,completions=0,cancelled=false
        owner.start(operation:{
            effects+=1
            let result=await withCheckedContinuation{release=$0}
            cancelled=Task.isCancelled;return result
        },completion:{_ in completions+=1})
        for _ in 0..<100 where release==nil{await Task.yield()}
        #expect(release != nil)
        owner.start(operation:{effects+=1;return true},completion:{_ in completions+=1})
        owner.stop();release?.resume(returning:true)
        for _ in 0..<10{await Task.yield()}
        #expect(effects==1);#expect(cancelled);#expect(completions==0)
    }
}
