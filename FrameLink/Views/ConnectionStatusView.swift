import MultipeerConnectivity
import SwiftUI

struct ConnectionStatusView: View {
    @ObservedObject var peers: PeerConnectionManager
    var cameraReady: Bool? = nil

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(peers.connectedName != nil ? Color.green : Color.secondary).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(cameraReady == false && peers.connectedName != nil ? "Connected, camera paused" : peers.status)
                    .font(.subheadline.weight(.medium))
                if let name = peers.connectedName {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if peers.isConnecting { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct NearbyDevicesView: View {
    @ObservedObject var peers: PeerConnectionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(peers.status)
                    if let name = peers.connectedName {
                        Label(name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    if peers.connectedName != nil || peers.isConnecting {
                        Button("Disconnect", role: .destructive, action: peers.restart)
                    }
                } header: { Text("Connection") }
                Section {
                    ForEach(peers.nearby, id: \.self) { peer in
                        Button {
                            peers.invite(peer)
                        } label: {
                            Label(peer.displayName, systemImage: "iphone")
                        }
                        .disabled(peers.connectedName != nil || peers.isConnecting)
                    }
                    if peers.nearby.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for preview iPhones…").foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Nearby previews") } footer: {
                    Text("Open Preview Mode on the other iPhone. Enable Wi-Fi and Bluetooth in Settings; no Wi-Fi network is needed. If nothing appears, allow Frame Link Local Network access on both phones. iOS may not report a denied permission as an error.")
                }
                Section {
                    Button("Search again", action: peers.restart)
                        .disabled(peers.connectedName != nil || peers.isConnecting)
                    Button("Open Settings", action: openSettings)
                }
            }
            .navigationTitle("Nearby devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
