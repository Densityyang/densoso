import DensosoDomain

enum DailyLoopConfirmationRefreshPolicy {
    static func shouldRefreshHealth(afterConfirming actionType: ActionType) -> Bool {
        switch actionType {
        case .meal, .weight, .workoutPlan, .trainingPlan, .dailyCheckIn, .userPreference:
            true
        }
    }
}
