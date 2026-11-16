import Foundation

/// Historical manual assessment, separate from the latest attempt and context.
/// Configurations must be canonical encodings of the decoded ruleSet alone.
public struct ManualTriggerHistory {
    public private(set) var preview=TriggerPreview()
    private var ruleSet:Data?
    public init() {}

    public mutating func configure(ruleSet:Data,rules:[TriggerPreview.Rule]) {
        guard self.ruleSet != ruleSet else { return }
        self.ruleSet=ruleSet
        if preview.checkedAt == nil { preview.rules=rules }
        else { preview.outdated=true }
    }
    public mutating func invalidate() {
        if preview.checkedAt != nil { preview.outdated=true }
    }
    public mutating func begin() { preview.checking=true;preview.checkError=nil }
    public mutating func cancel() { preview.checking=false }
    public mutating func fail(_ error:String) { preview.checking=false;preview.checkError=error }
    public mutating func complete(_ result:TriggerPreview) {
        guard result.checkedAt != nil,["ready","unknown"].contains(result.state) else {
            fail(result.checkError ?? "Couldn't check triggers. Try again.");return
        }
        preview=result;preview.checking=false;preview.outdated=false;preview.checkError=nil
    }
}
