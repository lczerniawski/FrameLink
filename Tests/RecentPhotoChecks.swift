import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

@main
struct RecentPhotoChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecentPhotoArchive(directory: directory)
        let initial = try archive.load()
        precondition(initial.isEmpty)
        let original = try photoData()
        try archive.add(original, assetIdentifier: "first-original/L0/001", capturedAt: Date(timeIntervalSince1970: 1_000))
        let first = try archive.load().first!
        precondition(first.assetIdentifier == "first-original/L0/001")
        let image = try RecentPhotoArchive.image(at: first.url)
        precondition(image.width == 1024 && image.height == 2048, "Apply EXIF rotation when downsampling")
        let thumbnail = try RecentPhotoArchive.image(at: first.url, maximumPixelSize: 160)
        precondition(max(thumbnail.width, thumbnail.height) <= 160)
        let source = CGImageSourceCreateWithURL(first.url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        precondition(properties[kCGImagePropertyGPSDictionary] == nil, "Private previews must not copy location metadata")
        let stored = try Data(contentsOf: first.url)
        precondition(stored != original, "Do not keep another full-resolution original")

        let unrelated = directory.appendingPathComponent("unrelated.jpg")
        try Data("not an app-owned preview".utf8).write(to: unrelated)
        for second in 1...22 {
            try archive.add(original, assetIdentifier: "asset-\(second)/L0/001",
                            capturedAt: Date(timeIntervalSince1970: 1_000 + Double(second)))
        }
        let photos = try archive.load()
        precondition(photos.count == 20)
        precondition(photos.first?.assetIdentifier == "asset-22/L0/001", "Persist the exact opaque Photos identifier in the preview")
        precondition(photos.first!.capturedAt == Date(timeIntervalSince1970: 1_022))
        precondition(photos.last!.capturedAt == Date(timeIntervalSince1970: 1_003))
        precondition(!FileManager.default.fileExists(atPath: first.url.path), "Prune old app previews")
        precondition(FileManager.default.fileExists(atPath: unrelated.path), "Never prune unrelated files")
        let reopened = RecentPhotoArchive(directory: directory)
        let restored = try reopened.load()
        precondition(restored.map(\.id) == photos.map(\.id), "Keep recent previews across relaunches")
        precondition(restored.map(\.assetIdentifier) == photos.map(\.assetIdentifier), "Asset links must survive relaunches")
        do {
            try archive.add(Data("invalid image".utf8), assetIdentifier: "invalid-image/L0/001")
            preconditionFailure("Invalid images must report an error")
        } catch RecentPhotoArchive.ArchiveError.invalidImage {}
        do {
            try archive.add(original, assetIdentifier: "")
            preconditionFailure("Every gallery entry must have a nonempty Photos reference")
        } catch RecentPhotoArchive.ArchiveError.invalidAssetReference {}
        let malformedID = String(format: "%020llu", UInt64(43)) + "_" + UUID().uuidString + ".jpg"
        let malformed = directory.appendingPathComponent(malformedID)
        try original.write(to: malformed)
        let afterFailure = try archive.load()
        precondition(afterFailure.count == 20, "Invalid image/reference data must not enter the gallery")
        do {
            try await archive.deleteFromBoth(malformedID) { _ in
                preconditionFailure("An invalid archive record must never select a Photos asset")
            }
            preconditionFailure("An invalid archive record must not be deletable")
        } catch RecentPhotoArchive.ArchiveError.previewNotFound {}
        precondition(FileManager.default.fileExists(atPath: malformed.path))
        do {
            _ = try RecentPhotoArchive.image(at: unrelated)
            preconditionFailure("A corrupted preview must report an error")
        } catch RecentPhotoArchive.ArchiveError.invalidImage {}
        let blocked = RecentPhotoArchive(directory: unrelated)
        do {
            try blocked.add(original, assetIdentifier: "blocked/L0/001")
            preconditionFailure("Storage errors must be reported")
        } catch {}
        let removed = [photos[0], photos[10], photos[19]]
        for photo in removed { try archive.remove(photo.id) }
        let remaining = try archive.load()
        let removedIDs = Set(removed.map(\.id))
        precondition(remaining.map(\.id) == photos.filter { !removedIDs.contains($0.id) }.map(\.id))
        precondition(remaining.count == 17, "Remove newest, middle, and oldest previews without changing order")
        let restoredAfterRemoval = try reopened.load()
        precondition(restoredAfterRemoval.map(\.id) == remaining.map(\.id), "Removal must persist across relaunches")
        do {
            try archive.remove(removed[0].id)
            preconditionFailure("Removing a missing preview must report an error")
        } catch RecentPhotoArchive.ArchiveError.previewNotFound {}
        do {
            try archive.remove(unrelated.lastPathComponent)
            preconditionFailure("Never remove unrelated files")
        } catch RecentPhotoArchive.ArchiveError.previewNotFound {}
        let outside = directory.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let externalID = String(format: "%020llu", UInt64(42)) + "_" + UUID().uuidString + ".jpg"
        let externalPhoto = outside.appendingPathComponent(externalID)
        try original.write(to: externalPhoto)
        for id in [externalPhoto.path, "Outside/\(externalID)", "../Outside/\(externalID)", externalID] {
            do {
                try archive.remove(id)
                preconditionFailure("Removal must stay inside the app-owned preview list")
            } catch RecentPhotoArchive.ArchiveError.previewNotFound {}
        }
        let untouched = try Data(contentsOf: externalPhoto)
        precondition(untouched == original, "Never remove or modify originals outside the archive")
        precondition(FileManager.default.fileExists(atPath: unrelated.path))
        for photo in remaining { try archive.remove(photo.id) }
        let emptied = try archive.load()
        precondition(emptied.isEmpty, "Removing the final preview must leave an empty gallery")
        try await checkLinkedDeletion(data: original, root: directory)
        print("Frame Link recent-photo checks passed")
    }

    private static func checkLinkedDeletion(data: Data, root: URL) async throws {
        let archive = RecentPhotoArchive(directory: root.appendingPathComponent("Linked", isDirectory: true))
        let identifier = "exact-original-id/L0/001"
        try archive.add(data, assetIdentifier: "untouched-original/L0/001", capturedAt: Date(timeIntervalSince1970: 1_500))
        try archive.add(data, assetIdentifier: identifier, capturedAt: Date(timeIntervalSince1970: 1_501))
        let photos = try archive.load()
        let linked = photos[0]
        let untouched = photos[1]
        let calls = OSAllocatedUnfairLock(initialState: [String]())

        enum Refusal: Error { case denied, limitedMissing, hiddenMissing, cancelled }
        for refusal in [Refusal.denied, .limitedMissing, .hiddenMissing, .cancelled] {
            do {
                try await archive.deleteFromBoth(linked.id) { id in
                    precondition(id == identifier)
                    calls.withLock { $0.append(id) }
                    throw refusal
                }
                preconditionFailure("A denied, inaccessible, or cancelled Photos deletion must not remove its preview")
            } catch is Refusal {}
            precondition(FileManager.default.fileExists(atPath: linked.url.path))
        }
        try await archive.deleteFromBoth(linked.id) { id in
            precondition(id == identifier, "Delete only the exact linked asset, never a date/image match")
            precondition(FileManager.default.fileExists(atPath: linked.url.path), "Photos must complete before cache removal")
            calls.withLock { $0.append(id) }
        }
        precondition(!FileManager.default.fileExists(atPath: linked.url.path))
        precondition(FileManager.default.fileExists(atPath: untouched.url.path))
        precondition(calls.withLock { $0.count } == 5)
        do {
            try await archive.deleteFromBoth(linked.id) { id in calls.withLock { $0.append(id) } }
            preconditionFailure("A missing gallery record must not request another Photos deletion")
        } catch RecentPhotoArchive.ArchiveError.previewNotFound {}
        precondition(calls.withLock { $0.count } == 5)

        let cleanup = RecentPhotoArchive(directory: root.appendingPathComponent("Cleanup", isDirectory: true))
        try cleanup.add(data, assetIdentifier: identifier)
        let cleanupPhoto = try cleanup.load()[0]
        let moved = root.appendingPathComponent("CleanupMoved", isDirectory: true)
        do {
            try await cleanup.deleteFromBoth(cleanupPhoto.id) { _ in
                try FileManager.default.moveItem(at: cleanup.directory, to: moved)
                try Data("unavailable cache directory".utf8).write(to: cleanup.directory)
            }
            preconditionFailure("A failure after Photos deletion must be distinguished from a Photos refusal")
        } catch RecentPhotoArchive.ArchiveError.previewCleanupFailed(let detail) {
            precondition(!detail.isEmpty)
        }
        try FileManager.default.removeItem(at: cleanup.directory)
        try FileManager.default.moveItem(at: moved, to: cleanup.directory)
        // The same Delete Photo action can finish cleanup after Photos has already confirmed deletion.
        try await cleanup.deleteFromBoth(cleanupPhoto.id) { _ in }
        precondition(!FileManager.default.fileExists(atPath: cleanupPhoto.url.path))
        precondition(calls.withLock { $0.count } == 5, "Finishing a confirmed deletion must not target another original")
    }

    private static func photoData() throws -> Data {
        let context = CGContext(data: nil, width: 4096, height: 2048, bitsPerComponent: 8, bytesPerRow: 4096 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2048))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
