import SwiftUI

struct RecentPhotosView: View {
    @ObservedObject var store: RecentPhotoStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String
    @State private var photoToRemove: RecentPhoto?
    @State private var galleryError: String?
    @StateObject private var loader = RecentPhotoLoader()

    init(store: RecentPhotoStore) {
        self.store = store
        _selectedID = State(initialValue: store.photos.first?.id ?? "")
    }

    private var photos: [RecentPhoto] { store.photos }
    private var selectedIndex: Int { photos.firstIndex(where: { $0.id == selectedID }) ?? 0 }

    var body: some View {
        NavigationStack {
            Group {
                if photos.isEmpty {
                    ContentUnavailableView("No recent photos", systemImage: "photo.on.rectangle",
                        description: Text("Photos you take in Camera Mode on this iPhone appear here."))
                } else {
                    TabView(selection: $selectedID) {
                        ForEach(photos) { photo in
                            ZStack {
                                Color.black
                                if photo.id == selectedID {
                                    if let image = loader.image, loader.photoID == photo.id {
                                        GeometryReader { geometry in
                                            Image(decorative: image, scale: 1)
                                                .resizable().aspectRatio(contentMode: .fit)
                                                .frame(width: geometry.size.width, height: geometry.size.height)
                                        }
                                        .accessibilityLabel("Photo taken \(photo.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                                    } else if let error = loader.errorMessage {
                                        VStack(spacing: 16) {
                                            ContentUnavailableView("Can’t load preview", systemImage: "exclamationmark.triangle",
                                                description: Text(error))
                                            Button("Try again") { loader.load(photo) }.buttonStyle(.bordered)
                                        }
                                    } else {
                                        ProgressView("Loading photo…")
                                    }
                                }
                            }
                            .tag(photo.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .allowsHitTesting(!store.isLoading)
                    .onChange(of: selectedID, initial: true) { _, id in
                        if let photo = photos.first(where: { $0.id == id }) { loader.load(photo) }
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Recent photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.isLoading {
                        ProgressView().accessibilityLabel("Updating gallery")
                    } else if let photo = photos.first(where: { $0.id == selectedID }) {
                        Button(role: .destructive) { photoToRemove = photo } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Delete photo")
                        .accessibilityHint("Deletes this photo from Photos and removes it from Recent photos")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(store.isLoading)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !photos.isEmpty {
                    HStack {
                        Button {
                            if selectedIndex > 0 { selectedID = photos[selectedIndex - 1].id }
                        } label: {
                            Image(systemName: "chevron.left").frame(width: 44, height: 44)
                        }
                        .disabled(selectedIndex == 0 || store.isLoading)
                        .accessibilityLabel("Newer photo")
                        Spacer()
                        VStack(spacing: 3) {
                            Text("\(selectedIndex + 1) of \(photos.count)").font(.subheadline.monospacedDigit())
                            Text(photos[selectedIndex].capturedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            if selectedIndex + 1 < photos.count { selectedID = photos[selectedIndex + 1].id }
                        } label: {
                            Image(systemName: "chevron.right").frame(width: 44, height: 44)
                        }
                        .disabled(selectedIndex == photos.count - 1 || store.isLoading)
                        .accessibilityLabel("Older photo")
                    }
                    .padding(.horizontal, 16).padding(.bottom, 8).background(Color.black)
                }
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: Binding(
            get: { photoToRemove != nil }, set: { if !$0 { photoToRemove = nil } }
        ), titleVisibility: .visible, presenting: photoToRemove) { photo in
            Button("Delete Photo", role: .destructive) { remove(photo) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This deletes the photo from Photos and Frame Link. If iCloud Photos is on, it also deletes the photo from your other devices. iOS may ask you to confirm.")
        }
        .alert("Couldn’t update recent photos", isPresented: Binding(
            get: { galleryError != nil }, set: { if !$0 { galleryError = nil } }
        )) {
            Button("Reload photos") { store.reload() }
            Button("Open Settings", action: openSettings)
            Button("OK", role: .cancel) {}
        } message: { Text(galleryError ?? "") }
        .onReceive(store.$errorMessage) { if let message = $0 { galleryError = message } }
        .onChange(of: photos.map(\.id)) { _, ids in
            if !ids.contains(selectedID) {
                loader.cancel()
                selectedID = ids.first ?? ""
            }
        }
        .interactiveDismissDisabled(store.isLoading)
        .onDisappear { loader.cancel() }
    }

    private func remove(_ photo: RecentPhoto) {
        guard !store.isLoading else { return }
        let index = photos.firstIndex(where: { $0.id == photo.id }) ?? 0
        let replacementID = photos.dropFirst(index + 1).first?.id ?? photos.prefix(index).last?.id
        loader.cancel()
        store.remove(photo) {
            if let current = photos.first(where: { $0.id == selectedID }) {
                loader.load(current)
            } else {
                selectedID = replacementID ?? photos.first?.id ?? ""
            }
        }
    }
}

/// Only one full-size preview is decoded at a time; cancelled pages never replace the current photo.
@MainActor
private final class RecentPhotoLoader: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var photoID: String?
    @Published private(set) var errorMessage: String?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var requestID = UUID()

    func load(_ photo: RecentPhoto) {
        cancel()
        photoID = photo.id
        let requestID = self.requestID
        queue.addOperation {
            let result = Result { try RecentPhotoArchive.image(at: photo.url) }
            DispatchQueue.main.async {
                guard self.requestID == requestID else { return }
                switch result {
                case .success(let image): self.image = image
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        queue.cancelAllOperations()
        requestID = UUID()
        image = nil
        errorMessage = nil
        photoID = nil
    }
}
