import AppKit
import UniformTypeIdentifiers
import CompanionCore

@MainActor enum FirebaseImportUI {
    static func choose()throws->FirebaseSenderConfiguration? {
        func file(_ title:String,_ message:String)throws->Data? {
            let panel=NSOpenPanel();panel.title=title;panel.message=message
            panel.allowedContentTypes=[.json];panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
            guard panel.runModal() == .OK,let url=panel.url else{return nil}
            let data=try Data(contentsOf:url);guard data.count<=65_536 else{throw CompanionError.limit};return data
        }
        guard let service=try file("Choose Firebase sender key","Choose the private service-account JSON for your own Firebase project. It stays on this Mac.") else{return nil}
        let client=try file("Choose Android Firebase configuration","Choose google-services.json for io.github.gbettineschi.keepressomobile from the same project. Only its public client options go to your phone.")
        return try CompanionCore.FirebaseSetup.importFiles(service:service,client:client)
    }
}
