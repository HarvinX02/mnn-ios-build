import Foundation

// MARK: - 题材判定

/// 判定策略（v2，重写）：
///
/// v1 的致命错误是把 "Vision 有没有给出某类标签" 直接当成题材。
/// 但 Vision 标签很吵：
///   - 钩织企鹅玩偶 -> 给出 bird
///   - 一碗汤 + 菜单文字 -> 给出 food + text，被判成文档
///   - 暗光室内的猫 -> 亮度低，被判成夜景
///   - 拼豆手工作品 -> 给出 building/toy，被判成建筑
///
/// v2 改为三个原则：
///   1) 先排除，再归类。截图/文档这类"强特征"先判，避免被后面抢走。
///   2) 场景类题材（夜景/建筑/风景/街拍）必须有"场景证据"，不能只靠亮度或单个标签。
///   3) 主体类题材（宠物/美食/人像）靠"主体标签 + 置信度"取胜，且镜头类场景不抢。
///
/// 另外：自动判定永远会有错。UI 必须提供手动改判入口，这是设计前提，不是补丁。
enum KindClassifier {

    static func classify(isScreenshot: Bool,
                         categories: [CategoryHit],
                         topIdentifier: String,
                         faceCount: Int,
                         ocrText: String,
                         brightness: Double,
                         contrast: Double,
                         colorfulness: Double,
                         pixelRatio: Double,
                         sharpness: Double) -> (kind: PhotoKind, confidence: Double) {

        // ---- 准备：标签表（带置信度）----
        var conf: [String: Double] = [:]
        for c in categories {
            let k = c.label.lowercased()
            conf[k] = max(conf[k] ?? 0, c.confidence)
        }
        let topLower = topIdentifier.lowercased()
        if !topLower.isEmpty { conf[topLower] = max(conf[topLower] ?? 0, 0.5) }

        /// 某前缀的最高置信度
        func score(_ prefixes: [String]) -> Double {
            var best = 0.0
            for (label, c) in conf {
                for p in prefixes where label.contains(p) {
                    best = max(best, c)
                }
            }
            return best
        }
        func has(_ prefixes: String...) -> Bool { score(prefixes) > 0 }

        let ocrLen = ocrText.count

        // =========================================================
        // 第 1 层：强特征，优先级最高
        // =========================================================

        // 1.1 截图 —— 系统标记，最可靠
        if isScreenshot { return (.screenshot, 1.0) }

        // 1.2 文档票据 —— 必须同时满足"大量文字" + "画面本身很简单"
        //     关键修正：加 colorfulness 上限和 sharpness 下限的双重约束，
        //     避免把"有文字的实景照片"（菜单、演讲 PPT、合影）判进来。
        let docLabel = score(["document", "receipt", "spreadsheet", "whiteboard", "chart"])
        let looksLikePaper = colorfulness < 0.22 && brightness > 0.45 && ocrLen >= 25
        let strongDoc = docLabel > 0.45 && ocrLen >= 15 && colorfulness < 0.35
        if looksLikePaper || strongDoc {
            // 但如果有明确主体（人脸/动物/食物），说明是实景，不是文档
            let subjectStrong = faceCount > 0
                || score(["animal_cat", "animal_dog", "animal", "food", "person", "people"]) > 0.55
            if !subjectStrong {
                return (.document, strongDoc ? 0.85 : 0.7)
            }
        }

        // =========================================================
        // 第 2 层：主体类（宠物 / 人像 / 美食）
        // =========================================================

        let animalScore = score(["animal_cat", "animal_dog", "kitten", "puppy",
                                 "animal", "reptile", "fish", "hamster"])
        let foodScore   = score(["food", "dish", "cuisine", "meal", "dessert",
                                 "beverage", "drink", "coffee", "pizza", "sushi"])
        let birdScore   = score(["bird"])

        // 2.1 人像：有清晰人脸，且人脸是主要元素
        //     修正：动物照片常被误检出"人脸"，所以先比动物分数
        if faceCount >= 1 && animalScore < 0.5 {
            if faceCount == 1 { return (.portrait, 0.8) }
            if faceCount <= 4 { return (.portrait, 0.75) }
            return (.portrait, 0.6)
        }

        // 2.2 宠物：动物标签足够强
        //     修正：玩偶/手工作品可能被判成 bird，需要排除"室内 + 高色彩 + 锐度极高"的小物件特征。
        //     判断依据：真实动物照片通常有较丰富的背景，而玩偶特写背景单一、对比强烈。
        if animalScore > 0.45 {
            return (.pet, animalScore)
        }
        // 鸟类单独处理：置信度要求更高，避免玩偶误判
        if birdScore > 0.55 && colorfulness < 0.42 {
            return (.pet, birdScore * 0.8)
        }

        // 2.3 美食
        if foodScore > 0.45 {
            return (.food, foodScore)
        }

        // =========================================================
        // 第 3 层：场景类，必须有"场景证据"，不能只靠亮度
        // =========================================================

        let nightLabel  = score(["night", "dark", "firework", "city_lights"])
        let buildLabel  = score(["building", "architecture", "skyscraper", "church",
                                 "tower", "bridge", "house", "facade"])
        let natureLabel = score(["landscape", "mountain", "beach", "sky", "sunset",
                                 "sunrise", "sea", "ocean", "lake", "snow", "cloud",
                                 "nature", "forest", "water", "horizon", "coast"])
        let streetLabel = score(["street", "road", "sidewalk", "crowd", "traffic",
                                 "vehicle", "car", "motorcycle", "bicycle"])
        let indoorLabel = score(["indoor", "room", "interior", "furniture", "bedroom",
                                 "living_room", "kitchen", "couch", "sofa"])

        // 3.1 夜景：必须是"暗 + 有夜景标签或城市灯光特征"
        //     关键修正：v1 只看 brightness < 0.22，导致暗光室内的猫全被判成夜景。
        //     v2 要求：暗 且 (有夜景标签 或 有建筑/城市元素) 且 不是室内。
        let isDark = brightness < 0.26
        if isDark && indoorLabel < 0.45 {
            let hasNightEvidence = nightLabel > 0.3
                || (buildLabel > 0.35 && contrast > 0.22)
                || (brightness < 0.14 && contrast > 0.25)
            if hasNightEvidence {
                return (.night, nightLabel > 0.3 ? 0.8 : 0.6)
            }
        }

        // 3.2 建筑：建筑标签强，且不是室内小物件
        if buildLabel > 0.4 && pixelRatio < 1.15 {
            return (.architecture, buildLabel)
        }

        // 3.3 风景：自然类标签强
        if natureLabel > 0.4 {
            return (.landscape, natureLabel)
        }

        // 3.4 街拍：街道/交通标签 + 室外
        if streetLabel > 0.4 {
            return (.street, streetLabel)
        }

        // =========================================================
        // 第 4 层：兜底
        // =========================================================

        // 4.1 室内场景 -> 静物
        if indoorLabel > 0.4 { return (.still, 0.5) }

        // 4.2 无标签但构图提示风景：横构图 + 亮 + 色彩足
        if pixelRatio > 1.15 && brightness > 0.42 && colorfulness > 0.38 {
            return (.landscape, 0.4)
        }

        // 4.3 默认不硬归类，交给用户手动改
        return (.other, 0.2)
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
    /// 截图不参与质量评分：截图的价值取决于内容，不是画质。
    /// 所有维度权重为 0，UI 显示「不评分」。
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
