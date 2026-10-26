import Foundation
import Testing
@testable import CompanionCore

struct InternetEvidenceTests {
    let now=Date(timeIntervalSince1970:1000)
    @Test func aWifiRouteIsNotProofOfInternetAndConcurrentReadsCoalesce(){
        var evidence=InternetEvidence()
        #expect(evidence.status(at:now)=="unknown")
        evidence.updatePath(available:true,identity:"wifi-A",now:now)
        #expect(evidence.status(at:now)=="checking")
        let check=evidence.beginCheck(now:now)
        #expect(check != nil)
        #expect(evidence.beginCheck(now:now)==nil)
        evidence.complete(check!,success:true,now:now)
        #expect(evidence.status(at:now)=="online")
        #expect(evidence.beginCheck(now:now.addingTimeInterval(14))==nil)
        #expect(evidence.beginCheck(now:now.addingTimeInterval(15)) != nil)
    }
    @Test func routeLossAndLateOldSuccessCannotClaimOnline(){
        var evidence=InternetEvidence()
        evidence.updatePath(available:true,identity:"wifi-A",now:now)
        let old=evidence.beginCheck(now:now)!
        evidence.updatePath(available:false,identity:"none",now:now)
        evidence.complete(old,success:true,now:now)
        #expect(evidence.status(at:now)=="offline")
        evidence.updatePath(available:true,identity:"wifi-B",now:now)
        evidence.complete(old,success:true,now:now)
        #expect(evidence.status(at:now)=="checking")
        #expect(evidence.checkedAt==nil)
    }
    @Test func failedChecksStayDistinctFromNoRouteAndOldEvidenceExpires(){
        var evidence=InternetEvidence()
        evidence.updatePath(available:true,identity:"wifi",now:now)
        evidence.complete(evidence.beginCheck(now:now)!,success:false,now:now)
        #expect(evidence.status(at:now)=="check_failed")
        #expect(evidence.status(at:now.addingTimeInterval(46))=="unknown")
        #expect(evidence.status(at:now.addingTimeInterval(-1))=="unknown")
    }
    @Test func stoppedMonitorRejectsLateCompletionAndDoesNotStartChecks(){
        var evidence=InternetEvidence()
        evidence.updatePath(available:true,identity:"wifi",now:now)
        let pending=evidence.beginCheck(now:now)!
        evidence.reset()
        evidence.complete(pending,success:true,now:now)
        #expect(evidence.status(at:now)=="unknown")
        #expect(evidence.beginCheck(now:now)==nil)
    }
    @Test func observingNoRouteAgainRenewsOnlyTheOfflineEvidence(){
        var evidence=InternetEvidence()
        evidence.updatePath(available:false,identity:"none",now:now)
        let later=now.addingTimeInterval(60)
        evidence.updatePath(available:false,identity:"none",now:later)
        #expect(evidence.status(at:later)=="offline")
        #expect(evidence.checkedAt==later)
    }
}
