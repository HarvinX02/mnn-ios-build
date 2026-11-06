import Foundation

// MARK: - 题材判定

/// 根据 Vision 标签、人脸数、截图标记、OCR 文本量、画面统计，
/// 推断这张照片属于哪一类题材。题材决定了后面用哪套评分标准。
enum KindClassifier {

    static func classify(isScreenshot: Bool,
                         categories: [CategoryHit],
                         topIdentifier: String,
                         faceCount: Int,
                         ocrText: String,
                         brightness: Double,
                         contrast: Double,
                         colorfulness: Double,
                         pixelRatio: Double) -> (kind: PhotoKind, confidence: Double) {

        let ids = categories.map { $0.label.lowercased() }
        let all = ([topIdentifier.lowercased()] + ids).filter { !$0.isEmpty }
        func has(_ keys: String...) -> Bool {
            all.contains { id in keys.contains { id.contains($0) } }
        }

        // 1) 截图：系统标记最可靠
        if isScreenshot { return (.screenshot, 1.0) }

        // 2) 文档票据：OCR 文字多 + 低色彩 + 近白底
        let ocrLen = ocrText.count
        if ocrLen > 40 && colorfulness < 0.35 && brightness > 0.55 {
            return (.document, 0.85)
        }
        if has("document", "receipt", "text", "chart") && ocrLen > 12 {
            return (.document, 0.75)
        }

        // 3) 人像：有脸，且不是大群人
        if faceCount >= 1 && faceCount <= 6 {
            return (.portrait, min(0.95, 0.55 + Double(faceCount) * 0.1))
        }

        // 4) 夜景：暗 + Vision 给 night / 亮度确实低
        if has("night", "firework", "concert") || (brightness < 0.22 && contrast > 0.18) {
            return (.night, has("night") ? 0.85 : 0.6)
        }

        // 5) 宠物 / 动物
        if has("animal_cat", "animal_dog", "animal", "bird", "insect", "reptile") {
            return (.pet, 0.8)
        }

        // 6) 美食
        if has("food", "drink", "coffee") {
            return (.food, 0.8)
        }

        // 7) 建筑：竖构图 + 建筑类标签
        if has("building", "architecture", "house", "interior", "room") {
            return (.architecture, 0.7)
        }

        // 8) 风景：自然类标签，且横构图、色彩较丰富
        if has("landscape", "mountain", "beach", "sky", "sunset", "sunrise",
               "sea", "lake", "snow", "cloud", "water", "nature", "tree") {
            return (.landscape, pixelRatio >= 1.0 ? 0.85 : 0.7)
        }

        // 9) 街拍：有人但脸识别不到（背影/远景）+ 城市场景
        if has("crowd", "street", "vehicle", "car", "transport", "figure") {
            return (.street, 0.6)
        }

        // 10) 静物：无明显主体、色彩集中
        if colorfulness < 0.5 && contrast > 0.12 {
            return (.still, 0.5)
        }

        // 11) 风景兜底：亮 + 色彩丰富 + 横构图
        if brightness > 0.45 && colorfulness > 0.45 {
            return (.landscape, 0.5)
        }

        return (.other, 0.3)
    }
}

// MARK: - 分题材评分

/// 核心：每个题材用不同的维度权重和不同的合格线。
/// 不存在"一张图一个绝对分数"，只有"在这类照片里，它达不达标"。
struct KindScorer {

    struct Weights {
        var sharpness: Double
        var exposure: Double
        var contrast: Double
        var color: Double
        var noise: Double
        var resolution: Double
    }

    /// 各题材权重（合计 = 1.0）
    /// 截图同样参与评分，但只评"可读性"：文字锐度 + 分辨率 + 对比度。
    /// 曝光和色彩对截图没有意义，权重归零。
    static func weights(for kind: PhotoKind) -> Weights {
        switch kind {
        case .screenshot:
            return Weights(sharpness: 0.58, exposure: 0.0, contrast: 0.17,
                           color: 0.0, noise: 0.05, resolution: 0.20)

        case .document:
            // 文档票据：锐度压倒一切，其次对比度（黑白分明）、低噪点。
            return Weights(sharpness: 0.50, exposure: 0.10, contrast: 0.22,
                           color: 0.0, noise: 0.10, resolution: 0.08)

        case .portrait:
            // 人像：锐度（眼睛/皮肤细节）、曝光（脸部亮度）、色彩（肤色）。
            return Weights(sharpness: 0.40, exposure: 0.22, contrast: 0.10,
                           color: 0.15, noise: 0.08, resolution: 0.05)

        case .landscape:
            // 风景：锐度、色彩、对比度都重要，曝光宽容度大。
            return Weights(sharpness: 0.35, exposure: 0.15, contrast: 0.18,
                           color: 0.20, noise: 0.05, resolution: 0.07)

        case .night:
            // 夜景：噪点是主要敌人，锐度次之，暗是正常的。
            return Weights(sharpness: 0.30, exposure: 0.10, contrast: 0.20,
                           color: 0.10, noise: 0.25, resolution: 0.05)

        case .food:
            // 美食：色彩（食欲）、锐度（质感）、曝光（不能死白）。
            return Weights(sharpness: 0.35, exposure: 0.20, contrast: 0.10,
                           color: 0.22, noise: 0.08, resolution: 0.05)

        case .pet:
            // 宠物：锐度（毛发）、曝光、噪点。
            return Weights(sharpness: 0.45, exposure: 0.18, contrast: 0.08,
                           color: 0.12, noise: 0.10, resolution: 0.07)

        case .still:
            // 静物特写：锐度 + 对比度。
            return Weights(sharpness: 0.45, exposure: 0.18, contrast: 0.15,
                           color: 0.10, noise: 0.07, resolution: 0.05)

        case .architecture:
            // 建筑：锐度（线条）、对比度、分辨率。
            return Weights(sharpness: 0.42, exposure: 0.15, contrast: 0.18,
                           color: 0.08, noise: 0.05, resolution: 0.12)

        case .street:
            // 街拍：锐度、对比度、噪点。
            return Weights(sharpness: 0.38, exposure: 0.18, contrast: 0.18,
                           color: 0.10, noise: 0.10, resolution: 0.06)

        case .other:
            return Weights(sharpness: 0.40, exposure: 0.20, contrast: 0.14,
                           color: 0.12, noise: 0.08, resolution: 0.06)
        }
    }

    /// 各题材的曝光最优区间（夜景本来就暗，不该按白天标准罚分）
    static func exposureWindow(for kind: PhotoKind) -> (low: Double, high: Double) {
        switch kind {
        case .night:      return (0.05, 0.40)
        case .screenshot: return (0.0, 1.0)     // 不计入评分
        case .document:   return (0.45, 0.90)
        case .portrait:   return (0.32, 0.70)
        default:          return (0.30, 0.72)
        }
    }

    /// 各题材的"合格锐度"参考值，低于此值视为该题材下的失败作。
    /// 截图/文档因为是大片纯色 + 细字，拉普拉斯方差天然偏低，门槛要下调。
    static func sharpnessFloor(for kind: PhotoKind) -> Double {
        switch kind {
        case .screenshot: return 0.16
        case .document:   return 0.15
        case .night:      return 0.18
        case .portrait:   return 0.30
        case .landscape:  return 0.34
        case .food:       return 0.30
        case .pet:        return 0.32
        case .architecture: return 0.32
        default:          return 0.28
        }
    }

    /// 计算分数 + 问题清单
    static func score(kind: PhotoKind,
                      sharpness: Double,
                      brightness: Double,
                      contrast: Double,
                      colorfulness: Double,
                      noise: Double,
                      megapixels: Double) -> (score: Double, issues: [PhotoIssue]) {

        let w = weights(for: kind)
        let win = exposureWindow(for: kind)

        // 曝光得分：在窗口内满分，窗口外线性衰减
        let expScore: Double
        if kind == .screenshot {
            expScore = 1.0
        } else if brightness < win.low {
            expScore = max(0, brightness / max(0.01, win.low))
        } else if brightness > win.high {
            let span = max(0.01, 1.0 - win.high)
            expScore = max(0, 1 - (brightness - win.high) / span)
        } else {
            expScore = 1.0
        }

        // 分辨率得分：截图目标是"能看清字"，约 3MP 就够
        let mpTarget: Double
        switch kind {
        case .screenshot: mpTarget = 2.5
        case .document:   mpTarget = 6.0
        default:          mpTarget = 10.0
        }
        let mpScore = min(1.0, megapixels / mpTarget)

        let noiseScore = 1.0 - noise

        var s = sharpness * w.sharpness
              + expScore * w.exposure
              + contrast * w.contrast
              + colorfulness * w.color
              + noiseScore * w.noise
              + mpScore * w.resolution

        // ---- 问题检出 ----
        var issues: [PhotoIssue] = []

        let floor = sharpnessFloor(for: kind)
        if sharpness < floor {
            issues.append(.blurry)
            let deficit = (floor - sharpness) / max(0.01, floor)
            s *= (1.0 - 0.45 * min(1.0, deficit))
        }

        if kind != .screenshot && kind != .night {
            if brightness < win.low * 0.62 { issues.append(.dark) }
            if brightness > 0.93 { issues.append(.overexposed) }
        }

        if kind != .screenshot && contrast < 0.10 {
            issues.append(.lowContrast)
        }

        if noise > 0.62 && kind != .screenshot {
            issues.append(.noisy)
        }

        // 分辨率：截图按 1MP 判定（低于此基本看不清内容）
        let resFloor: Double = (kind == .screenshot) ? 1.0 : 1.0
        if megapixels < resFloor {
            issues.append(.lowRes)
        }

        return (max(0, min(1, s)), issues)
    }
}
