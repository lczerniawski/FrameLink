import Combine
import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

struct RecentPhoto: Identifiable, Sendable {
    let url: URL
    let capturedAt: Date
    let assetIdentifier: String
    var id: String { url.lastPathComponent }
}

/// Stores app-owned previews and exact asset links; original deletion is supplied separately and must succeed first.
struct RecentPhotoArchive: Sendable {
    static let limit = 20
    static let maximumPixelSize = 2048
    let directory: URL
    private static let assetIdentifierPrefix = "Frame Link Photos asset: "

    func add(_ data: Data, assetIdentifier: String, capturedAt: Date = Date()) throws {
        guard !assetIdentifier.isEmpty else { throw ArchiveError.invalidAssetReference }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ArchiveError.invalidImage }
        let image = try Self.downsample(source, maximumPixelSize: Self.maximumPixelSize)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ArchiveError.invalidImage
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCaptionAbstract: Self.assetIdentifierPrefix + assetIdentifier
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ArchiveError.invalidImage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = String(format: "%020llu", UInt64(capturedAt.timeIntervalSince1970 * 1_000_000))
        let url = directory.appendingPathComponent("\(timestamp)_\(UUID().uuidString).jpg")
        try (output as Data).write(to: url, options: .atomic)
        for photo in try load().dropFirst(Self.limit) {
            try FileManager.default.removeItem(at: photo.url)
        }
    }

    func load() throws -> [RecentPhoto] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        return try urls.compactMap { url -> RecentPhoto? in
            guard url.pathExtension == "jpg" else { return nil }
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 20, let timestamp = UInt64(parts[0]),
                  UUID(uuidString: String(parts[1])) != nil,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
            let iptc = properties?[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
            guard let description = iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String,
                  description.hasPrefix(Self.assetIdentifierPrefix) else { return nil }
            let identifier = String(description.dropFirst(Self.assetIdentifierPrefix.count))
            guard !identifier.isEmpty else { return nil }
            return RecentPhoto(url: url, capturedAt: Date(timeIntervalSince1970: Double(timestamp) / 1_000_000),
                               assetIdentifier: identifier)
        }.sorted { $0.id > $1.id }
    }

    func remove(_ id: String) throws {
        guard let photo = try load().first(where: { $0.id == id }) else { throw ArchiveError.previewNotFound }
        try FileManager.default.removeItem(at: photo.url)
    }

    func deleteFromBoth(_ id: String, deleteOriginal: @Sendable (String) async throws -> Void) async throws {
        guard let photo = try load().first(where: { $0.id == id }) else { throw ArchiveError.previewNotFound }
        // Keep the preview until Photos confirms deletion; never infer an original from dates or image similarity.
        try await deleteOriginal(photo.assetIdentifier)
        do { try remove(id) }
        catch { throw ArchiveError.previewCleanupFailed(error.localizedDescription) }
    }

    static func image(at url: URL, maximumPixelSize: Int = maximumPixelSize) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ArchiveError.invalidImage }
        return try downsample(source, maximumPixelSize: maximumPixelSize)
    }

    private static func downsample(_ source: CGImageSource, maximumPixelSize: Int) throws -> CGImage {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw ArchiveError.invalidImage }
        return image
    }

    enum ArchiveError: LocalizedError {
        case invalidImage, previewNotFound, invalidAssetReference
        case previewCleanupFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "Couldn’t read or create the photo preview. If the photo was saved, you can still find the original in Photos."
            case .previewNotFound:
                return "This photo is no longer in Recent photos. Tap Reload photos to update the list."
            case .invalidAssetReference:
                return "Frame Link couldn’t link this photo to its original in Photos, so it wasn’t added to Recent photos."
            case .previewCleanupFailed(let detail):
                return "Deleted from Photos, but the preview couldn’t be removed from Frame Link. Try Delete Photo again before closing Frame Link. \(detail)"
            }
        }
    }
}

@MainActor
final class RecentPhotoStore: ObservableObject {
    @Published private(set) var photos: [RecentPhoto] = []
    @Published private(set) var thumbnail: CGImage?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    // shortcut: confirmed deletions last only this launch; persist receipts if recovery across app termination is required.
    private var confirmedOriginalDeletions: Set<String> = []
    private let archive: RecentPhotoArchive
    private let queue = DispatchQueue(label: "com.lczerniawski.framelink.recent-photos", qos: .userInitiated)

    init() {
        archive = RecentPhotoArchive(directory: URL.applicationSupportDirectory.appendingPathComponent("RecentPhotos", isDirectory: true))
        reload()
    }

    func reload() { perform() }

    func add(_ data: Data, assetIdentifier: String, completion: @escaping @MainActor @Sendable () -> Void) {
        perform(photo: (data, assetIdentifier), completion: completion)
    }

    func remove(_ photo: RecentPhoto, completion: @escaping @MainActor @Sendable () -> Void) {
        guard !isLoading else { return }
        let originalAlreadyDeleted = confirmedOriginalDeletions.contains(photo.id)
        isLoading = true
        errorMessage = nil
        let archive = self.archive
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await archive.deleteFromBoth(photo.id) { identifier in
                        if !originalAlreadyDeleted { try await PhotoLibraryDeletion.delete(identifier) }
                    }
                }.value
                confirmedOriginalDeletions.remove(photo.id)
                perform(completion: completion)
            } catch {
                isLoading = false
                if case RecentPhotoArchive.ArchiveError.previewCleanupFailed = error {
                    confirmedOriginalDeletions.insert(photo.id)
                }
                errorMessage = error.localizedDescription
                completion()
            }
        }
    }

    private func perform(photo: (data: Data, assetIdentifier: String)? = nil,
                         completion: (@MainActor @Sendable () -> Void)? = nil) {
        isLoading = true
        errorMessage = nil
        let archive = self.archive
        queue.async {
            let result = Result { () throws -> ([RecentPhoto], CGImage?, String?) in
                if let photo { try archive.add(photo.data, assetIdentifier: photo.assetIdentifier) }
                let photos = Array(try archive.load().prefix(RecentPhotoArchive.limit))
                do {
                    let thumbnail = try photos.first.map { try RecentPhotoArchive.image(at: $0.url, maximumPixelSize: 160) }
                    return (photos, thumbnail, nil)
                } catch {
                    return (photos, nil, error.localizedDescription)
                }
            }
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let (photos, thumbnail, warning)):
                    self.confirmedOriginalDeletions.formIntersection(photos.map(\.id))
                    self.photos = photos
                    self.thumbnail = thumbnail
                    self.errorMessage = warning
                case .failure(let error):
                    self.errorMessage = photo == nil
                        ? "Couldn’t load recent photos: \(error.localizedDescription)"
                        : "Saved to Photos, but Frame Link couldn’t store the preview: \(error.localizedDescription)"
                }
                completion?()
            }
        }
    }
}

private enum PhotoLibraryDeletion {
    static func delete(_ identifier: String) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw DeletionError.accessRequired }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        // Even full access can omit locked hidden assets; a missing fetch never proves the original is deleted.
        guard assets.count > 0 else { throw DeletionError.originalUnavailable }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
        } catch {
            throw DeletionError.notDeleted(error.localizedDescription)
        }
    }

    private enum DeletionError: LocalizedError {
        case accessRequired, originalUnavailable, notDeleted(String)
        var errorDescription: String? {
            switch self {
            case .accessRequired:
                return "The photo wasn’t deleted. Allow Frame Link Photos access in Settings, then try again. The preview is still in Frame Link."
            case .originalUnavailable:
                return "Frame Link can’t access the original in Photos. It may be hidden, outside your allowed selection, or already deleted. The preview is still here. Unhide the photo in Photos or update Frame Link’s Photos access in Settings, then try again."
            case .notDeleted(let detail):
                return "Photos didn’t confirm deletion. The preview is still in Frame Link. \(detail)"
            }
        }
    }
}
