enum MainMapCameraAnimationStyle: Equatable {
    case fastSnap
    case smoothFollow
}

enum MainMapCoordinator {
    struct FollowMode: Equatable {
        var isFollowingCourse: Bool

        static let following = FollowMode(isFollowingCourse: true)
        static let manual = FollowMode(isFollowingCourse: false)
    }

    enum CameraChangeDisposition: Equatable {
        case consumeProgrammaticChange
        case keepCurrentMode
        case disableFollowMode
    }

    static func toggledFollowMode(from mode: FollowMode) -> FollowMode {
        mode.isFollowingCourse ? .manual : .following
    }

    static func cameraChangeDisposition(
        isUpdatingCamera: Bool,
        isTestDriveActive: Bool,
        followMode: FollowMode
    ) -> CameraChangeDisposition {
        if isUpdatingCamera {
            return .consumeProgrammaticChange
        }
        if isTestDriveActive {
            return .keepCurrentMode
        }
        if followMode.isFollowingCourse {
            return .disableFollowMode
        }
        return .keepCurrentMode
    }

    static func cameraAnimationStyle(
        isTestDriveActive: Bool
    ) -> MainMapCameraAnimationStyle {
        if isTestDriveActive {
            return .fastSnap
        }
        return .smoothFollow
    }

    static func shouldShowCustomLocationDot(
        isTestDriveActive: Bool
    ) -> Bool {
        isTestDriveActive
    }
}
