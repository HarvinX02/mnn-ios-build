import Foundation

// MARK: - 分类命中

struct CategoryHit: Codable, Hashable {
    let label: String        // 原始 identifier，如 animal_cat
    let zh: String           // 中文名
    let confidence: Double
}

// MARK: - 照片类型（决定用什么标准评）

/// 关键设计：不同题材的照片，评价维度完全不同。
/// 截图没有"曝光"可言，夜景本来就该暗，文档要的是文字清晰而非色彩。
enum PhotoKind: String, Codable, CaseIterable, Identifiable {
    case screenshot   = "截图"
    case document     = "文档票据"
    case portrait     = "人像"
    case landscape    = "风景"
    case night        = "夜景"
    case food         = "美食"
    case pet          = "宠物"
    case still        = "静物特写"
    case architecture = "建筑"
    case street       = "街拍"
    case other        = "其他"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .screenshot:   return "rectangle.dashed"
        case .document:     return "doc.text"
        case .portrait:     return "person.crop.circle"
        case .landscape:    return "mountain.2"
        case .night:        return "moon.stars"
        case .food:         return "fork.knife"
        case .pet:          return "pawprint"
        case .still:        return "cube"
        case .architecture: return "building.2"
        case .street:       return "figure.walk"
        case .other:        return "photo"
        }
    }
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

// MARK: - 缺陷标记

/// 不再只给一个分数，而是明确告诉用户"哪里有问题"。
/// 截图/文档有各自的判定口径，不走同一套。
enum PhotoIssue: String, Codable, CaseIterable, Identifiable {
    case blurry      = "模糊"
    case dark        = "偏暗"
    case overexposed = "过曝"
    case lowContrast = "对比度低"
    case noisy       = "噪点多"
    case lowRes      = "分辨率低"
    case tilted      = "倾斜"
    case tiny        = "体积极小"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .blurry:      return "wind"
        case .dark:        return "moon"
        case .overexposed: return "sun.max"
        case .lowContrast: return "circle.lefthalf.filled"
        case .noisy:       return "aqi.medium"
        case .lowRes:      return "arrow.down.right.and.arrow.up.left"
        case .tilted:      return "rotate.right"
        case .tiny:        return "externaldrive"
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

    // 原始物理指标（不做跨题材比较，只作证据展示）
    var sharpness: Double           // 0...1 拉普拉斯方差归一化
    var exposure: Double            // 0...1 平均亮度
    var contrast: Double            // 0...1 亮度标准差
    var colorfulness: Double        // 0...1 Hasler-Süsstrunk
    var noise: Double               // 0...1 越高越脏
    var tiltDegrees: Double         // 地平线倾斜角度

    /// 按题材加权后的综合分（0...1）。不同 PhotoKind 权重不同。
    var qualityScore: Double
    var grade: QualityGrade

    /// 题材判定结果与置信度
    var kind: PhotoKind
    var kindConfidence: Double

    /// 检出的问题项
    var issues: [PhotoIssue]

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
        var parts: [String] = [primaryCategory, grade.rawValue, kind.rawValue]
        parts.append(contentsOf: categories.map { $0.zh })
        parts.append(contentsOf: categories.map { $0.label })
        parts.append(contentsOf: issues.map { $0.rawValue })
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
    var savings: Int64 {
        records.filter { $0.id != keeperID }.reduce(0) { $0 + ($1.fileSize ?? 0) }
    }
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
    case worst = "同类型最差优先"
    case best  = "同类型最好优先"
    case newest = "最新优先"
    case oldest = "最早优先"
    case largest = "体积最大优先"

    var id: String { rawValue }
}

// MARK: - 分类中文映射

enum CategoryMap {
    /// Vision 的 identifier 是英文层级（如 animal_cat），这里做前缀映射。
    /// 顺序有意义：更具体的放前面。
    static let table: [(prefix: String, zh: String)] = [
        ("animal_cat", "猫"),
        ("animal_dog", "狗"),
        ("animal_bird", "鸟"),
        ("reptile", "爬行动物"),
        ("animal", "动物"),
        ("bird", "鸟"),
        ("insect", "昆虫"),
        ("food_pizza", "披萨"),
        ("food_dessert", "甜点"),
        ("food_burger", "汉堡"),
        ("food_noodle", "面食"),
        ("food_rice", "米饭"),
        ("food_sushi", "寿司"),
        ("food", "食物"),
        ("drink", "饮品"),
        ("coffee", "咖啡"),
        ("plant", "植物"),
        ("flower", "花"),
        ("tree", "树"),
        ("nature", "自然"),
        ("landscape", "风景"),
        ("sky", "天空"),
        ("cloud", "云"),
        ("sunset", "日落"),
        ("sunrise", "日出"),
        ("beach", "海滩"),
        ("mountain", "山"),
        ("water", "水景"),
        ("sea", "海"),
        ("lake", "湖"),
        ("snow", "雪"),
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
        ("baby", "婴儿"),
        ("child", "儿童"),
        ("vehicle", "交通工具"),
        ("car", "汽车"),
        ("bicycle", "自行车"),
        ("motorcycle", "摩托"),
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
        ("concert", "演出"),
        ("firework", "烟花"),
    ]

    static func zh(for identifier: String) -> String {
        let low = identifier.lowercased()
        for row in table where low.contains(row.prefix) {
            return row.zh
        }
        return "其他"
    }
}
