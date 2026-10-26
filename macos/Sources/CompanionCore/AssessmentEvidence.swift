public enum AssessmentEvidence {
    /// Upstream readers that collapse input errors to false cannot establish a
    /// negative. A positive still records genuine observed matching evidence.
    public static func positiveOnly(_ upstreamSatisfied:Bool)->Bool? { upstreamSatisfied ? true:nil }
}
