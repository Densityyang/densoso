enum ToolSchemaVersion {
    static let legacy = 1
    static let current = 2

    static func supportsRestore(_ version: Int) -> Bool {
        version == legacy || version == current
    }
}
