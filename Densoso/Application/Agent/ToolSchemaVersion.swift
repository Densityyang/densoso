enum ToolSchemaVersion {
    static let legacy = 1
    static let previous = 2
    static let current = 3

    static func supportsRestore(_ version: Int) -> Bool {
        version == legacy || version == previous || version == current
    }
}
