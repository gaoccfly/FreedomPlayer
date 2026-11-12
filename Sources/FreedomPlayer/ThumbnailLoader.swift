@preconcurrency import AVFoundation
import AppKit

actor ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private var memory = [String: NSImage]()

    func image(for url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let img = memory[key] { return img }
        if let img = Self.loadDisk(key: key) {
            memory[key] = img
            return img
        }
        let img = await Self.generate(url: url)
        if let img {
            memory[key] = img
            Self.saveDisk(img, key: key)
        }
        return img
    }

    func clearCache() {
        memory.removeAll()
        let dir = Self.cacheDir()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 磁盘缓存

    private static func cacheDir() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreedomPlayerThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(_ key: String) -> URL {
        var h: UInt64 = 5381
        for b in key.utf8 { h = (h &* 33) &+ UInt64(b) }
        return cacheDir().appendingPathComponent(String(h) + ".jpg")
    }

    private static func loadDisk(key: String) -> NSImage? {
        guard let data = try? Data(contentsOf: cacheURL(key)) else { return nil }
        return NSImage(data: data)
    }

    private static func saveDisk(_ img: NSImage, key: String) {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
        try? jpeg.write(to: cacheURL(key), options: .atomic)
    }

    // MARK: - 抽帧

    private static func generate(url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let time = CMTime(seconds: min(duration * 0.25, max(duration - 0.1, 0)), preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var actual = CMTime.zero
                if let cg = try? generator.copyCGImage(at: time, actualTime: &actual) {
                    continuation.resume(returning: NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
