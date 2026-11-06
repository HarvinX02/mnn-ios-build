import Foundation

// 题材判定（KindClassifier）已迁到 Evidence.swift，改成"多源证据"方案：
//   系统元数据 -> 动物识别 -> 人体检测 -> 文字覆盖率 -> 显著主体 -> 标签
// 这里只保留"按题材评分"的部分。

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
    /// 截图不参与质量评分：截图的价值取决于内容，不是画质。
    static func weights(for kind: PhotoKind) -> Weights {
        switch kind {
        case .screenshot:
            return Weights(sharpness: 0.0, exposure: 0.0, contrast: 0.0,
                           color: 0.0, noise: 0.0, resolution: 0.0)

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

    /// 计算分数 + 问题清单。
    /// 返回 score = -1 表示该题材不参与评分（截图）。
    static func score(kind: PhotoKind,
                      sharpness: Double,
                      brightness: Double,
                      contrast: Double,
                      colorfulness: Double,
                      noise: Double,
                      megapixels: Double) -> (score: Double, issues: [PhotoIssue]) {

        // 截图：不评分，只保留尺寸过小的提示
        if kind == .screenshot {
            var issues: [PhotoIssue] = []
            if megapixels < 0.3 { issues.append(.lowRes) }
            return (-1, issues)
        }

        let w = weights(for: kind)
        let win = exposureWindow(for: kind)

        // 曝光得分：在窗口内满分，窗口外线性衰减
        let expScore: Double
        if brightness < win.low {
            expScore = max(0, brightness / max(0.01, win.low))
        } else if brightness > win.high {
            let span = max(0.01, 1.0 - win.high)
            expScore = max(0, 1 - (brightness - win.high) / span)
        } else {
            expScore = 1.0
        }

        // 分辨率得分
        let mpTarget: Double = (kind == .document) ? 6.0 : 10.0
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

        if kind != .night {
            if brightness < win.low * 0.62 { issues.append(.dark) }
            if brightness > 0.93 { issues.append(.overexposed) }
        }

        if kind != .screenshot && contrast < 0.10 {
            issues.append(.lowContrast)
        }

        if noise > 0.62 {
            issues.append(.noisy)
        }

        if megapixels < 1.0 {
            issues.append(.lowRes)
        }

        return (max(0, min(1, s)), issues)
    }
}
