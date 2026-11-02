import Combine
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var role: PeerConnectionManager.Role?
    @Published private(set) var isForeground = false
    let peers: PeerConnectionManager
    let camera: CameraManager

    init() {
        let peers = PeerConnectionManager()
        self.peers = peers
        camera = CameraManager(encoder: peers.encoder, recentPhotos: RecentPhotoStore())
    }

    func select(_ role: PeerConnectionManager.Role?) {
        guard role != self.role else { return }
        stopServices()
        self.role = role
        if isForeground { startServices() }
    }

    func setActive(_ active: Bool) {
        guard active != isForeground else { return }
        isForeground = active
        if active { startServices() } else { stopServices() }
    }

    private func startServices() {
        guard let role else { return }
        peers.start(role)
        if role == .camera { camera.start() }
    }

    private func stopServices() {
        camera.stop()
        peers.stop()
    }
}
