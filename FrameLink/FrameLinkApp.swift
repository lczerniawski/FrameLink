import SwiftUI

@main
struct FrameLinkApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator, camera: coordinator.camera, peers: coordinator.peers)
                .preferredColorScheme(.dark)
                .tint(.yellow)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Permission dialogs are inactive, not background; do not tear down an invitation for them.
                    if phase == .active { coordinator.setActive(true) }
                    else if phase == .background { coordinator.setActive(false) }
                }
        }
    }
}

private struct RootView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var camera: CameraManager
    @ObservedObject var peers: PeerConnectionManager

    private var errorPresented: Binding<Bool> {
        Binding(get: { camera.errorMessage != nil || peers.errorMessage != nil }, set: { value in
            if !value {
                if camera.errorMessage != nil { camera.errorMessage = nil }
                if peers.errorMessage != nil { peers.errorMessage = nil }
            }
        })
    }

    var body: some View {
        NavigationStack {
            home
                .navigationTitle("Frame Link")
                .navigationBarTitleDisplayMode(.large)
                .background(Color.black)
                .navigationDestination(item: Binding(get: { coordinator.role }, set: { coordinator.select($0) })) { role in
                    Group {
                        switch role {
                        case .camera:
                            CameraView(camera: camera, peers: peers, recentPhotos: camera.recentPhotos)
                        case .preview:
                            PreviewView(peers: peers)
                        }
                    }
                    .navigationTitle(role == .camera ? "Camera Mode" : "Preview Mode")
                    .navigationBarTitleDisplayMode(.inline)
                    .background(Color.black)
                }
        }
        .alert("Frame Link", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
            Button("Open Settings") { openSettings() }
        } message: {
            Text(camera.errorMessage ?? peers.errorMessage ?? "")
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("One camera.\nA second point of view.")
                    .font(.largeTitle.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 24)
                Text("Keep both iPhones nearby and Frame Link open. Choose a different mode on each phone.")
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    modeButton("Camera Mode", subtitle: "Take photos on this iPhone", icon: "camera", role: .camera)
                    Divider().padding(.leading, 64)
                    modeButton("Preview Mode", subtitle: "Monitor the other iPhone’s camera", icon: "viewfinder", role: .preview)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                Label("No internet, router, or account needed", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline)
                Text("Turn on Wi-Fi and Bluetooth in Settings. Neither iPhone needs to join a Wi-Fi network. Allow Local Network access when asked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func modeButton(_ title: String, subtitle: String, icon: String, role: PeerConnectionManager.Role) -> some View {
        Button { coordinator.select(role) } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
            }
            .padding(20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}
