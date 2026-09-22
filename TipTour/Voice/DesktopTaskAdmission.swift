import Foundation

/// The existing coordinator owns the task. This is only the shared desktop
/// admission boundary; it stores no independent progress or completion state.
@MainActor
enum DesktopTaskAdmission {
    private static weak var owner: DesktopTaskCoordinator?

    static func reserve(for coordinator: DesktopTaskCoordinator) -> Bool {
        if let owner, owner !== coordinator, owner.hasPersistentReservation { return false }
        owner = coordinator
        return true
    }

    static var allowsCurrentTask: Bool {
        guard let owner, owner.hasPersistentReservation else { return true }
        return DesktopTaskExecutionContext.ownerID == owner.executionOwnerID && owner.mayDispatch
    }
}

enum DesktopTaskExecutionContext {
    @TaskLocal static var ownerID: UUID?
}
