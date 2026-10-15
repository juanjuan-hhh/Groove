import AppKit
import ImageIO
import Observation

/// 封面加载顺序：在「联网搜索」里手动选的 → 文件内嵌 → 同文件夹的 cover.jpg / folder.jpg → 之前联网下载的缓存
@MainActor
@Observable
final class ArtworkProvider {
    static let shared = ArtworkProvider()

    /// 联网下载到新封面后 +1，界面据此刷新
    private(set) var revision = 0

    /// 最多缓存 400 张（列表缩略图 + 正在播放的大图），内存紧张时系统也会自动清理
    @ObservationIgnored private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    @ObservationIgnored private var missing = Set<String>()
    static let buckets: [CGFloat] = [56, 200, 400]

    private struct Decoded: @unchecked Sendable { let image: CGImage }

    /// 已经在内存里的封面（不读文件、不等待）。界面第一帧就能直接显示，不会先空一下再跳出来
    func cachedImage(for track: Track, size: CGFloat) -> NSImage? {
        cache.object(forKey: Self.key(track, size))
    }

    private static func key(_ track: Track, _ size: CGFloat) -> NSString {
        let bucket = buckets.first { size <= $0 } ?? buckets.last!
        return "\(track.path)#\(Int(bucket))" as NSString
    }

    func image(for track: Track, size: CGFloat) async -> NSImage? {
        let bucket = Self.buckets.first { size <= $0 } ?? Self.buckets.last!
        let key = Self.key(track, size)
        if let image = cache.object(forKey: key) { return image }
        if missing.contains(track.path) { return nil }

        let maxPixel = Int(bucket * 2)
        let decoded = await Task.detached(priority: .utility) { () -> Decoded? in
            guard let data = await ArtworkProvider.loadData(for: track),
                  let cg = ArtworkProvider.downsample(data, maxPixel: maxPixel) else { return nil }
            return Decoded(image: cg)
        }.value

        guard let decoded else {
            missing.insert(track.path)
            return nil
        }
        let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        cache.setObject(image, forKey: key)
        return image
    }

    func invalidate(_ track: Track) {
        missing.remove(track.path)
        for bucket in Self.buckets {
            cache.removeObject(forKey: "\(track.path)#\(Int(bucket))" as NSString)
        }
        revision += 1
    }

    nonisolated static func loadData(for track: Track) async -> Data? {
        if let data = OnlineMedia.manualCover(track) { return data }
        if let data = await MetadataReader.embeddedArtwork(url: track.url) { return data }
        let folder = URL(fileURLWithPath: track.folderPath)
        for name in ["cover.jpg", "cover.png", "folder.jpg", "folder.png", "front.jpg", "Cover.jpg", "Folder.jpg", "AlbumArt.jpg"] {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { return data }
        }
        return OnlineMedia.cachedCover(track)
    }

    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
