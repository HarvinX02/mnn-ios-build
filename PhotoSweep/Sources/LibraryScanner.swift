import Foundation
import Photos
import UIKit

// MARK: - 相册资产的轻量信息（值类型，可跨线程传递）

struct AssetInfo: Sendable {
    let id: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let fileSize: Int64?
    let isScreenshot: Bool
    let isVideo: Bool

    var megapixels: Double {
        Double(pixelWidth * pixelHeight) / 1_000_000.0
    }
}

/// 把 non-Sendable 的 PHAsset 从枚举阶段"提纯"成纯值类型，
/// 后续分析只依赖 AssetInfo + localIdentifier，避免跨 actor 传递 PHAsset。
private func makeInfo(_ asset: PHAsset) -> AssetInfo {
    let res = PHAssetResource.assetResources(for: asset)
    let size = res.first?.value(forKey: "fileSize") as? Int64
    return AssetInfo(
        id: asset.localIdentifier,
        creationDate: asset.creationDate,
        pixelWidth: asset.pixelWidth,
        pixelHeight: asset.pixelHeight,
        fileSize: size,
        isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
        isVideo: asset.mediaType == .video
    )
}

// MARK: - 扫描引擎

@MainActor
final class LibraryScanner: ObservableObject {

    @Published private(set) var phase: ScanPhase = .idle
    @Published private(set) var records: [PhotoRecord] = []
    @Published private(set) var groups: [SimilarGroup] = []

    /// 扫描结束后给用户的一句说明（例如"没有新照片"）
    @Published var lastMessage: String = ""

    private let store = RecordStore()

    /// 是否对文字类照片做 OCR。关闭可提速约 30%。
    var enableOCR = true

    private var cancelFlag = false

    // MARK: 权限

    func requestPermission() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited { return true }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
                cont.resume(returning: st == .authorized || st == .limited)
            }
        }
    }

    // MARK: 缓存

    func loadCache() {
        if let saved = store.load() {
            records = saved
            groups = SimilarGrouper.group(saved)
            phase = .finished
        }
    }

    // MARK: 扫描

    /// force = true 时忽略已有结果，全部重扫。
    /// 之前的实现里 todo 为空会静默 return，按钮按下去毫无反应，
    /// 这里补上明确的状态反馈。
    func startScan(force: Bool = false) {
        guard !phase.isRunning else { return }
        cancelFlag = false
        Task { await runScan(force: force) }
    }

    func cancel() {
        cancelFlag = true
    }

    private func runScan(force: Bool) async {
        phase = .enumerating

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: opts)

        var infos: [AssetInfo] = []
        infos.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            infos.append(makeInfo(asset))
        }

        if infos.isEmpty {
            phase = .failed("相册里没有找到照片。\n请确认系统设置 → 照片 → 本 App 已获授权。")
            return
        }

        let doneIDs = force ? [] : Set(records.map { $0.id })
        let todo = infos.filter { !doneIDs.contains($0.id) }

        if todo.isEmpty {
            // 全部已分析过：不静默返回，给出明确结果
            groups = SimilarGrouper.group(records)
            phase = .finished
            lastMessage = "没有新照片。已有 \(records.count) 张分析结果。\n如需按新标准重算，请点「全部重新扫描」。"
            return
        }

        if force { records = [] }
        lastMessage = ""

        phase = .analyzing(done: 0, total: todo.count)

        let batchSize = 4
        let useOCR = enableOCR
        var fresh = force ? [] : records

        for chunkStart in stride(from: 0, to: todo.count, by: batchSize) {
            if cancelFlag {
                phase = .idle
                break
            }
            let end = min(chunkStart + batchSize, todo.count)
            let chunk = Array(todo[chunkStart..<end])

            let partial = await Self.analyzeChunk(chunk, useOCR: useOCR)
            fresh.append(contentsOf: partial)

            let done = min(chunkStart + batchSize, todo.count)
            phase = .analyzing(done: done, total: todo.count)

            // 每 40 张落盘一次，防中途被杀丢进度
            if done % 40 < batchSize {
                records = fresh
                store.save(fresh)
            }
        }

        records = fresh
        store.save(fresh)
        groups = SimilarGrouper.group(fresh)
        if !cancelFlag { phase = .finished }
    }

    /// 并行分析一批。全部静态，不触碰 self，规避 actor 隔离问题。
    private static func analyzeChunk(_ chunk: [AssetInfo],
                                     useOCR: Bool) async -> [PhotoRecord] {
        await withTaskGroup(of: PhotoRecord?.self) { group in
            for info in chunk {
                group.addTask {
                    await analyzeOne(info, useOCR: useOCR)
                }
            }
            var out: [PhotoRecord] = []
            for await r in group {
                if let r { out.append(r) }
            }
            return out
        }
    }

    /// 取图 + 分析，全程在后台执行
    private static func analyzeOne(_ info: AssetInfo,
                                   useOCR: Bool) async -> PhotoRecord? {
        let img = await loadImage(id: info.id)
        guard let img else { return nil }
        let analyzer = PhotoAnalyzer()
        return analyzer.analyze(image: img, assetInfo: info, includeOCR: useOCR)
    }

    private static func loadImage(id: String) async -> UIImage? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true   // iCloud 照片也能拉下来

        return await withCheckedContinuation { cont in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1024, height: 1024),
                contentMode: .aspectFit,
                options: options
            ) { img, _ in
                if resumed { return }
                resumed = true
                cont.resume(returning: img)
            }
        }
    }

    // MARK: 手动改判

    /// 用户手动改判某张照片的题材，并用新题材的权重重新打分。
    func overrideKind(ids: [String], to kind: PhotoKind?) {
        let set = Set(ids)
        for i in records.indices where set.contains(records[i].id) {
            records[i].manualKind = kind
            // 用该题材的标准重算分数
            let scored = KindScorer.score(
                kind: records[i].effectiveKind,
                sharpness: records[i].sharpness,
                brightness: records[i].exposure,
                contrast: records[i].contrast,
                colorfulness: records[i].colorfulness,
                noise: records[i].noise,
                megapixels: records[i].megapixels
            )
            records[i].qualityScore = scored.score
            records[i].grade = QualityGrade.from(score: scored.score)
            records[i].issues = scored.issues
        }
        store.save(records)
        groups = SimilarGrouper.group(records)
    }

    /// 恢复自动判定
    func clearKindOverride(ids: [String]) {
        overrideKind(ids: ids, to: nil)
    }

    // MARK: 删除

    func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { ok, err in
                if ok {
                    cont.resume()
                } else {
                    cont.resume(throwing: err ?? NSError(domain: "photosweep.delete",
                                                         code: -1))
                }
            }
        }
        let set = Set(ids)
        records.removeAll { set.contains($0.id) }
        store.save(records)
        groups = SimilarGrouper.group(records)
    }

    func clearAll() {
        records = []
        groups = []
        store.clear()
        phase = .idle
    }
}
