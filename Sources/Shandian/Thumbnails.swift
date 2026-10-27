import AppKit
import Foundation

/// 缩略图缓存在 Application Support/ShandianDownload/thumbs/<任务 id>.jpg。
/// 电影：用 ffmpeg 从视频里截一帧（下到一部分也能截，失败过一会再试）；视频网站：下载站点给的封面。
@MainActor
final class Thumbnails: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private var attempts: [String: (count: Int, last: Date)] = [:]
    private var inFlight = Set<String>()
    private let dir = EngineConfig.supportDir.appendingPathComponent("thumbs")
    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    init() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    func image(for id: String) -> NSImage? {
        if let img = images[id] { return img }
        let file = dir.appendingPathComponent("\(id).jpg")
        if let img = NSImage(contentsOf: file) { images[id] = img; return img }
        return nil
    }

    /// 从本地视频文件截帧。progress 太低时文件头可能还没下到，跳过；失败最多重试 6 次、间隔 30 秒
    func requestFrame(id: String, video: URL, progress: Double) {
        guard images[id] == nil, image(for: id) == nil, !inFlight.contains(id), progress > 0.08 || progress >= 1 else { return }
        if let a = attempts[id], a.count >= 6 || Date().timeIntervalSince(a.last) < 30 { return }
        guard let ffmpeg = Self.ffmpeg, FileManager.default.fileExists(atPath: video.path) else { return }
        inFlight.insert(id)
        attempts[id] = ((attempts[id]?.count ?? 0) + 1, Date())
        let out = dir.appendingPathComponent("\(id).jpg")
        Task.detached {
            // 片头常是黑场或片商标，取第 3 分钟左右；短片取第 10 秒
            var ok = false
            for ss in ["180", "10"] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ffmpeg)
                p.arguments = ["-v", "error", "-y", "-ss", ss, "-i", video.path, "-frames:v", "1", "-vf", "scale=480:-2", "-q:v", "4", out.path]
                p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
                if p.terminationStatus == 0, let s = try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int, s > 2000 { ok = true; break }
            }
            let img = ok ? NSImage(contentsOf: out) : nil
            await MainActor.run {
                self.inFlight.remove(id)
                if let img { self.images[id] = img }
            }
        }
    }

    func requestRemote(id: String, url: String?) {
        guard let url, let u = URL(string: url), images[id] == nil, image(for: id) == nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        let out = dir.appendingPathComponent("\(id).jpg")
        Task.detached {
            var img: NSImage?
            if let (data, _) = try? await URLSession.shared.data(from: u), let src = NSImage(data: data),
               let tiff = src.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? jpg.write(to: out); img = src
            }
            await MainActor.run { self.inFlight.remove(id); if let img { self.images[id] = img } }
        }
    }
}
