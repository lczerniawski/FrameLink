import SwiftUI

struct PreviewView: View {
    @ObservedObject var peers: PeerConnectionManager
    @State private var mirrored = false

    var body: some View {
        ZStack {
            Color.black
            if let image = peers.image {
                GeometryReader { geometry in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .accessibilityLabel("Live preview from the connected camera")
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "viewfinder").font(.system(size: 54, weight: .ultraLight))
                        Text(peers.connectedName == nil ? "Ready to connect" : "Waiting for video")
                            .font(.title2.weight(.semibold))
                        Text("On the other iPhone, open Camera Mode. Tap Nearby devices and choose this iPhone:")
                            .foregroundStyle(.secondary)
                        Text(peers.localPeer.displayName).font(.headline).textSelection(.enabled)
                        Text("Accept the connection request here. Keep Frame Link open on both iPhones, with Wi-Fi and Bluetooth on.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if peers.connectedName == nil {
                            Button("Try again", action: peers.restart).buttonStyle(.bordered)
                            Button("Open Settings", action: openSettings)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.center)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ConnectionStatusView(peers: peers).padding(.horizontal, 16).padding(.vertical, 10).background(Color.black)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Toggle(isOn: $mirrored) { Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .toggleStyle(.button)
                    .accessibilityHint("Flips this preview horizontally without changing saved photos")
                Spacer()
                if peers.isReceiving {
                    Text("\(peers.receivedFPS) fps").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("\(peers.receivedFPS) received frames per second")
                }
                if peers.connectedName != nil || peers.isConnecting {
                    Button("Disconnect", action: peers.restart)
                }
            }
            .padding(16).background(Color.black)
        }
        .alert("Allow camera connection?", isPresented: Binding(
            get: { peers.invitation != nil },
            set: { if !$0, peers.invitation != nil { peers.answerInvitation(false) } }
        ), presenting: peers.invitation) { _ in
            Button("Accept") { peers.answerInvitation(true) }
            Button("Decline", role: .cancel) { peers.answerInvitation(false) }
        } message: { invitation in
            Text("\(invitation.name) wants to share its camera preview with this iPhone. Accept only requests from an iPhone you recognize.")
        }
    }
}
