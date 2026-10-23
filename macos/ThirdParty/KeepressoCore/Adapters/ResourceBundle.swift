import Foundation
// SwiftPM native emits an accessor that requires resources in an app's root,
// which cannot be sealed by codesign. Keep upstream .module calls untouched and
// provide a companion-only locator for the original, unmodified localization
// resources under the standard Contents/Resources path. Unit tests fall back
// to untranslated original keys when running as a command-line test bundle.
extension Bundle {
    static let module:Bundle = {
        if let resources=Bundle.main.resourceURL,let bundle=Bundle(url:resources.appendingPathComponent("KeepressoCore.bundle")){return bundle}
        return .main
    }()
}
