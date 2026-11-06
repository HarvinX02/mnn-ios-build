import Foundation

// MARK: - 结果持久化

final class RecordStore {

    private var url: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // v2：评分模型改为分题材后，旧缓存没有 kind/issues 字段，直接换文件名丢弃
        return dir.appendingPathComponent("photosweep_records_v2.json")
    }

    func save(_ records: [PhotoRecord]) {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            // 存储失败不阻断扫描
        }
    }

    func load() -> [PhotoRecord]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode([PhotoRecord].self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 相似 / 连拍分组

enum SimilarGrouper {

    /// 汉明距离
    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    /// 按 64 位指纹聚类，阈值越小越严格。
    /// 用并查集合并，避免链式误合并。
    static func group(_ records: [PhotoRecord], threshold: Int = 10) -> [SimilarGroup] {
        let n = records.count
        guard n > 1 else { return [] }

        var parent = Array(0..<n)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        // O(n^2) 在所有照片上跑太慢，先按创建时间做窗口限制
        let sorted = records.enumerated().sorted {
            ($0.element.creationDate ?? .distantPast) < ($1.element.creationDate ?? .distantPast)
        }

        let window = 40   // 只看时间上相邻的 40 张
        for i in 0..<sorted.count {
            let limit = min(sorted.count, i + window)
            guard i + 1 < limit else { continue }
            for j in (i + 1)..<limit {
                let a = sorted[i], b = sorted[j]
                // 时间差超过 10 秒的不算连拍
                if let da = a.element.creationDate, let db = b.element.creationDate {
                    if abs(db.timeIntervalSince(da)) > 10 { continue }
                }
                // 宽高比差异大的排除
                let ra = Double(a.element.pixelWidth) / Double(max(1, a.element.pixelHeight))
                let rb = Double(b.element.pixelWidth) / Double(max(1, b.element.pixelHeight))
                if abs(ra - rb) > 0.06 { continue }

                if hamming(a.element.dhash, b.element.dhash) <= threshold {
                    union(a.offset, b.offset)
                }
            }
        }

        // 收集
        var buckets: [Int: [Int]] = [:]
        for i in 0..<n {
            buckets[find(i), default: []].append(i)
        }

        var out: [SimilarGroup] = []
        for (_, indices) in buckets where indices.count > 1 {
            let recs = indices.map { records[$0] }
            // 保留画质最高的那张
            let keeper = recs.max { $0.qualityScore < $1.qualityScore }!
            let id = recs.map { $0.id }.sorted().joined(separator: "|")
            out.append(SimilarGroup(id: id,
                                    records: recs,
                                    keeperID: keeper.id))
        }

        return out.sorted { $0.count > $1.count }
    }
}
