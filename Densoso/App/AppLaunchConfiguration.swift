import Foundation

struct AppLaunchConfiguration: Equatable {
    let isUITesting: Bool
    let usesSeededProfile: Bool

    static var current: AppLaunchConfiguration {
        let process = ProcessInfo.processInfo
        return resolve(arguments: process.arguments, environment: process.environment)
    }

    static func resolve(
        arguments: [String],
        environment: [String: String]
    ) -> AppLaunchConfiguration {
        let arguments = Set(arguments)
        let isUITesting = arguments.contains("-ui-testing")
            || environment["DENSOSO_UI_TESTING"] == "1"
        return AppLaunchConfiguration(
            isUITesting: isUITesting,
            usesSeededProfile: isUITesting && arguments.contains("-ui-testing-seeded")
        )
    }
}
