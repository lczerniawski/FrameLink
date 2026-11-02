import Combine
import MultipeerConnectivity
import UIKit

@MainActor
final class PeerConnectionManager: NSObject, ObservableObject {
    enum Role: Hashable { case camera, preview }
    struct Invitation: Identifiable {
        let id = UUID()
        let name: String
    }
    static let serviceType = "framelink"
    @Published private(set) var nearby: [MCPeerID] = []
    @Published private(set) var status = "Not connected"
    @Published private(set) var connectedName: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var isReceiving = false
    @Published private(set) var image: CGImage?
    @Published private(set) var receivedFPS = 0
    @Published var invitation: Invitation?
    @Published var errorMessage: String?

    let encoder = VideoEncoder()
    private let decoder = VideoDecoder()
    let localPeer = MCPeerID(displayName: "iPhone-\(UUID().uuidString.prefix(4))")
    private var role: Role?
    private var session: MCSession?
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var partner: MCPeerID?
    private var invitationHandler: ((Bool, MCSession?) -> Void)?
    private var invitationTimeout: Task<Void, Never>?
    private var connectionTimeout: Task<Void, Never>?
    private var monitor: Timer?
    private var lastFrame = Date.distantPast
    private var fpsStart = Date()
    private var frameCount = 0

    override init() {
        super.init()
        encoder.onError = { [weak self] message in
            Task { @MainActor in self?.fail(message) }
        }
    }

    func start(_ role: Role) {
        stop()
        self.role = role
        let session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
        if role == .camera {
            status = "Looking for iPhones"
            let browser = MCNearbyServiceBrowser(peer: localPeer, serviceType: Self.serviceType)
            browser.delegate = self
            self.browser = browser
            browser.startBrowsingForPeers()
        } else {
            status = "Ready to connect"
            let advertiser = MCNearbyServiceAdvertiser(peer: localPeer,
                discoveryInfo: ["role": "preview", "version": "1"], serviceType: Self.serviceType)
            advertiser.delegate = self
            self.advertiser = advertiser
            advertiser.startAdvertisingPeer()
        }
        monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        role = nil
        invitationHandler?(false, nil)
        invitationHandler = nil
        invitation = nil
        invitationTimeout?.cancel()
        connectionTimeout?.cancel()
        monitor?.invalidate()
        monitor = nil
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        browser = nil
        advertiser = nil
        encoder.connect(session: nil)
        let oldSession = session
        session = nil
        oldSession?.disconnect()
        partner = nil
        nearby = []
        connectedName = nil
        isConnecting = false
        isReceiving = false
        image = nil
        receivedFPS = 0
        UIApplication.shared.isIdleTimerDisabled = false
        status = "Not connected"
    }

    func restart() {
        guard let role else { return }
        start(role)
    }

    func invite(_ peer: MCPeerID) {
        guard role == .camera, let session, partner == nil else { return }
        partner = peer
        isConnecting = true
        status = "Waiting for \(peer.displayName)…"
        browser?.invitePeer(peer, to: session, withContext: Data("FrameLink/1/camera".utf8), timeout: 30)
        armConnectionTimeout(session)
    }

    func answerInvitation(_ accept: Bool) {
        let handler = invitationHandler
        invitationHandler = nil
        invitation = nil
        invitationTimeout?.cancel()
        if accept, let session {
            isConnecting = true
            status = "Connecting…"
            advertiser?.stopAdvertisingPeer()
            handler?(true, session)
            armConnectionTimeout(session)
        } else {
            handler?(false, nil)
            partner = nil
            status = "Ready to connect"
        }
    }

    private func armConnectionTimeout(_ expected: MCSession) {
        connectionTimeout?.cancel()
        connectionTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(32))
            guard !Task.isCancelled, let self, self.session === expected, self.connectedName == nil else { return }
            self.fail("The connection request was declined or timed out. Keep Frame Link open on both iPhones, check Local Network access in Settings, and try again.")
        }
    }

    private func fail(_ message: String) {
        restart()
        errorMessage = message
    }

    private func tick() {
        if encoder.checkForStall() {
            fail("The other iPhone stopped responding. Select it in Nearby devices to reconnect.")
        }
        if isReceiving, Date().timeIntervalSince(lastFrame) > 3 {
            isReceiving = false
            image = nil
            receivedFPS = 0
            status = "Connected, waiting for video"
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func receive(_ packet: Packet, from peer: MCPeerID, in incomingSession: MCSession) {
        guard session === incomingSession, partner == peer, connectedName != nil else { return }
        switch packet.kind {
        case .acknowledgement:
            guard role == .camera else { return }
            encoder.acknowledge(packet.sequence)
        case .notice:
            guard let message = String(data: packet.payload, encoding: .utf8) else {
                fail("Frame Link couldn’t read a message from the other iPhone. Try connecting again.")
                return
            }
            status = "Connected, \(message)"
        case .jpeg:
            guard role == .preview else { return }
            decoder.decode(packet.payload) { [weak self, weak incomingSession] image in
                guard let self, let incomingSession, self.session === incomingSession else { return }
                guard let image else { self.fail("Frame Link couldn’t display the incoming preview. Try connecting again."); return }
                self.image = image
                self.lastFrame = Date()
                self.frameCount += 1
                let elapsed = Date().timeIntervalSince(self.fpsStart)
                if elapsed >= 1 {
                    self.receivedFPS = Int((Double(self.frameCount) / elapsed).rounded())
                    self.frameCount = 0
                    self.fpsStart = Date()
                }
                self.isReceiving = true
                self.status = "Receiving preview"
                UIApplication.shared.isIdleTimerDisabled = true
                do {
                    try incomingSession.send(Packet(kind: .acknowledgement, sequence: packet.sequence).encoded(),
                                             toPeers: [peer], with: .reliable)
                } catch {
                    self.fail("The preview connection failed. Try connecting again. \(error.localizedDescription)")
                }
            }
        }
    }
}

extension PeerConnectionManager: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard self.browser === browser, info?["role"] == "preview", info?["version"] == "1" else { return }
            if !self.nearby.contains(peerID) { self.nearby.append(peerID) }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard self.browser === browser else { return }
            self.nearby.removeAll { $0 == peerID }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            guard self.browser === browser else { return }
            self.status = "Can’t find nearby iPhones"
            self.errorMessage = "Couldn’t search for nearby iPhones. Turn on Wi-Fi and Bluetooth and allow Frame Link Local Network access in Settings. \(error.localizedDescription)"
        }
    }
}

extension PeerConnectionManager: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                               withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { invitationHandler(false, nil); return }
            guard self.advertiser === advertiser, self.partner == nil,
                  self.role == .preview, context == Data("FrameLink/1/camera".utf8) else {
                invitationHandler(false, nil)
                return
            }
            self.partner = peerID
            self.invitationHandler = invitationHandler
            self.invitation = Invitation(name: peerID.displayName)
            self.invitationTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                self?.answerInvitation(false)
            }
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            guard self.advertiser === advertiser else { return }
            self.status = "This iPhone isn’t discoverable"
            self.errorMessage = "Other iPhones can’t find this iPhone. Check Frame Link’s Local Network access in Settings and try again. \(error.localizedDescription)"
        }
    }
}

extension PeerConnectionManager: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            guard self.session === session, self.partner == peerID else { return }
            switch state {
            case .connecting:
                self.isConnecting = true
                self.status = "Connecting…"
            case .connected:
                self.connectionTimeout?.cancel()
                self.connectedName = peerID.displayName
                self.isConnecting = false
                self.status = self.role == .camera ? "Streaming preview" : "Connected, waiting for video"
                self.fpsStart = Date()
                self.frameCount = 0
                if self.role == .camera {
                    self.encoder.connect(session: session, peer: peerID)
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                self.advertiser?.stopAdvertisingPeer()
            case .notConnected:
                let hadConnection = self.connectedName != nil
                self.restart()
                self.errorMessage = hadConnection
                    ? "Disconnected from \(peerID.displayName). Keep Frame Link open on both iPhones, then reconnect from Nearby devices in Camera Mode."
                    : "The connection was declined or failed. Check the other iPhone and try again."
            @unknown default:
                self.fail("The connection failed. Try connecting again.")
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = Packet(data: data) else {
            Task { @MainActor in
                guard self.session === session else { return }
                self.fail("Frame Link couldn’t read data from the other iPhone. Use the same app version on both iPhones and reconnect.")
            }
            return
        }
        Task { @MainActor in self.receive(packet, from: peerID, in: session) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) { progress.cancel() }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
