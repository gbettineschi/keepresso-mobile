import Foundation
import Testing
@testable import CompanionCore

private final class BlockingRead: @unchecked Sendable {
    let entered=DispatchSemaphore(value:0), release=DispatchSemaphore(value:0)
    func read()->SavedAuthorization { entered.signal();_ = release.wait(timeout:.now()+5);return SavedAuthorization(devices:[],relay:nil) }
}
struct SavedAuthorizationLoaderTests {
    @Test @MainActor func slowKeychainReadDoesNotBlockSettingsOrStartTwoReaders() async throws {
        let read=BlockingRead();let loader=SavedAuthorizationLoader();var completions=0
        loader.load(operation:{read.read()}){_ in completions+=1}
        var entered=false
        for _ in 0..<100 {
            if read.entered.wait(timeout:.now()) == .success{entered=true;break}
            try await Task.sleep(for:.milliseconds(10))
        }
        // The provider is now blocked: settings' actor must still be responsive.
        #expect(entered);#expect(loader.state == .loading);#expect(completions==0)
        loader.load(operation:{Issue.record("Duplicate Keychain read");return read.read()}){_ in completions+=1}
        read.release.signal()
        for _ in 0..<100 where loader.state == .loading { try await Task.sleep(for:.milliseconds(10)) }
        #expect(loader.state == .ready);#expect(completions==1)
    }
    @Test @MainActor func deniedReadStaysClosedAndAnExplicitRetryCanRecover() async throws {
        let loader=SavedAuthorizationLoader();var authorizations=0
        loader.load(operation:{throw CompanionError.unavailable}){_ in authorizations+=1}
        for _ in 0..<100 where loader.state == .loading { try await Task.sleep(for:.milliseconds(10)) }
        #expect(loader.state == .unavailable);#expect(authorizations==0)
        loader.load(operation:{SavedAuthorization(devices:[],relay:nil)}){_ in authorizations+=1}
        for _ in 0..<100 where loader.state == .loading { try await Task.sleep(for:.milliseconds(10)) }
        #expect(loader.state == .ready);#expect(authorizations==1)
    }
    @Test @MainActor func shutdownDiscardsAnOutstandingKeychainResult() async throws {
        let read=BlockingRead();let loader=SavedAuthorizationLoader();var authorizations=0
        loader.load(operation:{read.read()}){_ in authorizations+=1}
        loader.stop();read.release.signal()
        try await Task.sleep(for:.milliseconds(50))
        #expect(loader.state == .idle);#expect(authorizations==0)
    }
}
