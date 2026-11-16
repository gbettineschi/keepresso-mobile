import Foundation
import Testing
@testable import CompanionCore

@MainActor struct FirebaseSetupTests {
    private func files()throws->(Data,Data) {
        let c=try FirebaseSenderTests().config()
        let service=try WireJSON.data(["type":"service_account","project_id":c.projectId,"client_email":c.clientEmail,"private_key":c.privateKey,"token_uri":"https://oauth2.googleapis.com/token"])
        let client=try WireJSON.data(["project_info":["project_id":c.projectId,"project_number":c.client.senderId],"client":[["client_info":["mobilesdk_app_id":c.client.applicationId,"android_client_info":["package_name":"io.github.gbettineschi.keepressomobile"]],"api_key":[["current_key":c.client.apiKey]]]]])
        return(service,client)
    }
    @Test func importIsAtomicCancelledRetryableAndPairingIndependent()throws {
        let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let seed=PrivateInternetState(url:root.appendingPathComponent("internet/seed.json")),original=try seed.loadOrCreateSeed()
        let store=FirebaseSenderStorage(url:root.appendingPathComponent("push/sender.json"))
        let (service,client)=try files()
        #expect(try FirebaseSetup.importFiles(service:service,client:nil)==nil)
        #expect(try store.load()==nil)
        let imported=try #require(try FirebaseSetup.importFiles(service:service,client:client))
        try store.save(imported)
        #expect(throws:Error.self){try FirebaseSetup.importFiles(service:Data("{}".utf8),client:client)}
        var bad=try WireJSON.object(client);bad["project_info"]=["project_id":"other-project","project_number":"123456"]
        #expect(throws:Error.self){try FirebaseSetup.importFiles(service:service,client:WireJSON.data(bad))}
        #expect(try store.load()?.projectId=="keepresso-test")
        let replacement=try #require(try FirebaseSetup.importFiles(service:service,client:client))
        try store.save(replacement)
        #expect(try seed.loadOrCreateSeed()==original)
    }
    @Test func legacyBootstrapStopsOnlyAfterThisPairHasAuthenticatedOnInternet()throws {
        let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("internet/migration.json")
        let phone=AuthorizedDevice(deviceId:"22222222-2222-4222-8222-222222222222",name:"Fixture",key:Data(repeating:0x42,count:32),approvedAt:Date())
        let state=try InternetMigration(url:url)
        #expect(state.needsLegacy([phone]))
        try state.authenticated(phone)
        #expect(!state.needsLegacy([phone]))
        #expect(try !InternetMigration(url:url).needsLegacy([phone]))
        let changed=AuthorizedDevice(deviceId:phone.deviceId,name:phone.name,key:Data(repeating:7,count:32),approvedAt:phone.approvedAt)
        #expect(state.needsLegacy([changed]))
        #expect(!state.needsLegacy([]))
    }
}
