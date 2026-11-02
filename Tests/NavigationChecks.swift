import SwiftUI

// Service doubles exercise the real coordinator without starting camera or network hardware.
@MainActor final class PeerConnectionManager {
    enum Role: Hashable { case camera, preview }
    let encoder = 0
    var starts: [Role] = []
    var stops = 0
    func start(_ role: Role) { starts.append(role) }
    func stop() { stops += 1 }
}

@MainActor final class CameraManager {
    var starts = 0
    var stops = 0
    init(encoder: Int, recentPhotos: RecentPhotoStore) {}
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor final class RecentPhotoStore {}

@main struct NavigationChecks {
    @MainActor static func main() {
        let coordinator = AppCoordinator()
        let selection = Binding(get: { coordinator.role }, set: { coordinator.select($0) })
        precondition(selection.wrappedValue == nil)
        coordinator.setActive(true)

        for role in [PeerConnectionManager.Role.camera, .preview] {
            let stops = coordinator.peers.stops
            let starts = coordinator.peers.starts.count
            selection.wrappedValue = role
            precondition(coordinator.role == role)
            precondition(coordinator.peers.starts.last == role)
            precondition(coordinator.peers.stops == stops + 1)
            precondition(coordinator.camera.starts == 1, "Only Camera Mode starts the camera")

            selection.wrappedValue = role
            precondition(coordinator.peers.starts.count == starts + 1, "Navigation updates must not restart the same mode")
            precondition(coordinator.peers.stops == stops + 1)

            selection.wrappedValue = nil
            precondition(coordinator.role == nil, "A native back pop returns to the main menu")
            precondition(coordinator.peers.stops == stops + 2)
            precondition(coordinator.camera.stops == stops + 2, "Returning home stops both services")
            selection.wrappedValue = nil
            precondition(coordinator.peers.stops == stops + 2, "Repeated pop updates must be harmless")
            precondition(coordinator.camera.stops == stops + 2)
        }

        coordinator.setActive(false)
        let starts = coordinator.peers.starts.count
        selection.wrappedValue = .camera
        precondition(coordinator.peers.starts.count == starts, "Do not start services in the background")
        coordinator.setActive(true)
        precondition(coordinator.peers.starts.count == starts + 1)
        precondition(coordinator.camera.starts == 2)
        selection.wrappedValue = nil
        precondition(coordinator.role == nil)
        print("Frame Link navigation lifecycle checks passed")
    }
}
