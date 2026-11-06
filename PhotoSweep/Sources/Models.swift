import Foundation

// MARK: - 分类命中

struct CategoryHit: Codable, Hashable {
    let label: String        // 原始 identifier，如 animal_cat
    let zh: String           // 中文名
    let confidence: Double
}

// MARK: - 质量等级

enum QualityGrade: String, Codable, CaseIterable, Identifiable {
    case excellent = "优秀"
    case good      = "良好"
    case fair      = "一般"
    case poor      = "较差"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .excellent: return "star.fill"
        case .good:      return "hand.thumbsup.fill"
        case .fair:      return "equal.circle"
        case .poor:      return "exclamationmark.triangle.fill"
        }
    }

    static func from(score: Double) -> QualityGrade {
        switch score {
        case 0.78...: return .excellent
        case 0.62..<0.78: return .good
        case 0.42..<0.62: return .fair
        default: return .poor
        }
    }
}

// MARK: - 单张照片记录

struct PhotoRecord: Codable, Identifiable, Hashable {
    let id: String                  // PHAsset.localIdentifier
    var creationDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64?
    var isScreenshot: Bool
    var isVideo: Bool

    // 画质指标
    var sharpness: Double           // 0...1，拉普拉斯方差归一化
    var exposure: Double            // 0...1，平均亮度
    var contrast: Double            // 0...1
    var colorfulness: Double        // 0...1
    var qualityScore: Double        // 0...1 综合
    var grade: QualityGrade

    // 内容
    var categories: [CategoryHit]
    var primaryCategory: String     // 中文主分类
    var ocrText: String
    var faceCount: Int

    // 去重
    var dhash: UInt64

    var analyzedAt: Date

    var megapixels: Double {
        Double(pixelWidth * pixelHeight) / 1_000_000.0
    }

    var aspectLabel: String {
        guard pixelHeight > 0 else { return "-" }
        let r = Double(pixelWidth) / Double(pixelHeight)
        if r > 1.2 { return "横" }
        if r < 0.83 { return "竖" }
        return "方"
    }

    /// 搜索用全文索引
    var searchBlob: String {
        var parts: [String] = [primaryCategory, grade.rawValue]
        parts.append(contentsOf: categories.map { $0.zh })
        parts.append(contentsOf: categories.map { $0.label })
        parts.append(ocrText)
        if isScreenshot { parts.append("截图") }
        if faceCount > 0 { parts.append("人像 人脸") }
        if isVideo { parts.append("视频") }
        return parts.joined(separator: " ").lowercased()
    }
}

// MARK: - 相似分组

struct SimilarGroup: Identifiable, Hashable {
    let id: String
    let records: [PhotoRecord]
    let keeperID: String            // 建议保留的那张

    var count: Int { records.count }
    var savings: Int64 { records.reduce(0) { $0 + ($1.fileSize ?? 0) } }
}

// MARK: - 扫描状态

enum ScanPhase: Equatable {
    case idle
    case enumerating
    case analyzing(done: Int, total: Int)
    case finished
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .enumerating, .analyzing: return true
        default: return false
        }
    }
}

// MARK: - 排序

enum SortKey: String, CaseIterable, Identifiable {
    case worst = "画质最差优先"
    case best  = "画质最好优先"
    case newest = "最新优先"
    case oldest = "最早优先"
    case largest = "体积最大优先"

    var id: String { rawValue }
}

// MARK: - 分类中文映射

enum CategoryMap {
    /// Vision 的 identifier 是英文层级（如 animal_cat），这里做前缀映射
    static let table: [(prefix: String, zh: String)] = [
        ("animal_cat", "猫"),
        ("animal_dog", "狗"),
        ("animal", "动物"),
        ("bird", "鸟"),
        ("insect", "昆虫"),
        ("food_pizza", "披萨"),
        ("food_dessert", "甜点"),
        ("food", "食物"),
        ("drink", "饮品"),
        ("plant", "植物"),
        ("flower", "花"),
        ("tree", "树"),
        ("nature", "自然"),
        ("landscape", "风景"),
        ("sky", "天空"),
        ("sunset", "日落"),
        ("beach", "海滩"),
        ("mountain", "山"),
        ("water", "水景"),
        ("building", "建筑"),
        ("architecture", "建筑"),
        ("house", "房屋"),
        ("interior", "室内"),
        ("room", "房间"),
        ("furniture", "家具"),
        ("people", "人物"),
        ("person", "人物"),
        ("selfie", "自拍"),
        ("portrait", "人像"),
        ("crowd", "人群"),
        ("vehicle", "交通工具"),
        ("car", "汽车"),
        ("bicycle", "自行车"),
        ("transport", "交通"),
        ("text", "文字"),
        ("document", "文档"),
        ("receipt", "票据"),
        ("screenshot", "截图"),
        ("chart", "图表"),
        ("art", "艺术"),
        ("painting", "绘画"),
        ("toy", "玩具"),
        ("sport", "运动"),
        ("clothing", "服饰"),
        ("bag", "包"),
        ("shoe", "鞋"),
        ("electronic", "电子设备"),
        ("computer", "电脑"),
        ("phone", "手机"),
        ("furnishing", "家居"),
        ("kitchen", "厨房"),
        ("bathroom", "卫浴"),
        ("night", "夜景"),
    ]

    static func zh(for identifier: String) -> String {
        let low = identifier.lowercased()
        for row in table where low.contains(row.prefix) {
            return row.zh
        }
        return "其他"
    }
}
