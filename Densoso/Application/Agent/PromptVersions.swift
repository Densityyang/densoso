/// Increment these identifiers when the corresponding prompt contract changes.
/// They are stable labels for diagnostics and version-aware conversation handling;
/// they are deliberately kept out of user-visible prompt text.
enum AgentPromptVersion {
    static let current = "agent-v4"
}

enum NarrativePromptVersion {
    static let current = "health-narrative-v3"
}

enum MealPromptVersion {
    static let current = "meal-v2"
}

enum VisionPromptVersion {
    static let current = "meal-vision-v2"
}
