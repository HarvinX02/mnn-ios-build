import Foundation

// MARK: - 规则版本

/// 判定规则 / 特征提取的版本号。
/// 只要改动这里的逻辑或 PhotoAnalyzer 提取的特征，就必须 +1。
/// 否则手机上会一直显示旧缓存的结果，看起来像"改了没用"。
enum AnalyzerVersion {
    static let current = 4
}

// MARK: - 证据集

/// 判定一张照片"是什么题材"所需要的全部证据。
///
/// v1/v2 的做法是：Vision 给了个标签 -> 直接当成事实。
/// 但 Vision 的标签很吵（钩织企鹅 -> bird，拼豆 -> building，汤+菜单 -> document），
/// 只调整阈值永远修不完。
///
/// v3 改成"多源证据"，每个字段都是一个独立的、语义明确的测量：
///   - 系统元数据：截图/全景，准确率 100%
///   - 动物识别：VNRecognizeAnimals，只认猫狗，玩偶基本不触发
///   - 人体检测：VNDetectHumanRectangles，猫不会触发；玩偶娃娃也不会
///   - 文字覆盖率：OCR 框并集占画面比例，"满屏文字"和"照片里有个菜单"完全不同
///   - 显著主体：attention saliency，判断"是不是一个居中的特写小物件"
///   - 纸张/屏幕四边形：有没有一整块纸或屏幕
struct PhotoEvidence {

    // ---- 硬特征（系统元数据）----
    var isScreenshot = false
    var isPanorama = false
    var isPNG = false
    var isLivePhoto = false

    // ---- 物理统计 ----
    var pixelRatio = 1.0
    var brightness = 0.5
    var contrast = 0.3
    var colorfulness = 0.3
    var sharpness = 0.5
    var noise = 0.1

    // ---- 语义（Vision）----
    /// 图像分类的全部标签（已过滤低置信度）
    var labels: [(id: String, conf: Double)] = []
    /// 动物识别的最高置信度（只有 Cat / Dog 两类）
    var animalConf = 0.0
    var animalLabel = ""
    /// 人脸
    var faceCount = 0
    var maxFaceArea = 0.0          // 归一化面积占比 0...1
    /// 人体
    var humanCount = 0
    var maxHumanArea = 0.0
    /// OCR：文字框并集占比 / 行数 / 平均行高占比
    var textCoverage = 0.0
    var textLines = 0
    var textHeightRatio = 0.0
    /// 检测到的最大纸/屏四边形占比
    var maxQuadArea = 0.0
    /// 显著主体占比
    var saliencyArea = 0.0

    /// 某组前缀标签的最高置信度
    func conf(_ prefixes: [String]) -> Double {
        var best = 0.0
        for l in labels {
            let id = l.id.lowercased()
            for p in prefixes where id.contains(p) {
                if l.conf > best { best = l.conf }
            }
        }
        return best
    }

    /// 主要标签的简短描述，用于展示与诊断
    var topLabelsText: String {
        labels.prefix(4)
            .map { "\($0.id) \(String(format: "%.2f", $0.conf))" }
            .joined(separator: "、")
    }
}

// MARK: - 判定结果

struct KindVerdict {
    let kind: PhotoKind
    let confidence: Double
    /// 判定的依据，逐条给人看（详情页"为什么这么判"）
    let reasons: [String]
}

// MARK: - 证据驱动的分类器

enum EvidenceClassifier {

    static func classify(_ e: PhotoEvidence) -> KindVerdict {
        var why: [String] = []
        func r(_ s: String) { why.append(s) }
        func out(_ k: PhotoKind, _ c: Double) -> KindVerdict {
            KindVerdict(kind: k, confidence: min(0.98, max(0.05, c)), reasons: why)
        }

        // =========================================================
        // 0. 系统元数据：这一层永远正确，先判掉
        // =========================================================
        if e.isScreenshot {
            r("系统标记为截图（PHAsset.mediaSubtypes）")
            return out(.screenshot, 1.0)
        }
        if e.isPanorama {
            r("系统标记为全景照片")
            return out(.landscape, 0.9)
        }

        // =========================================================
        // 1. 各维度证据
        // =========================================================
        let animal = e.animalConf
        let food = e.conf(["food", "dish", "cuisine", "meal", "dessert",
                           "beverage", "coffee", "pizza", "sushi", "noodle",
                           "rice", "burger", "salad", "soup", "bakery"])
        let doc = e.conf(["document", "receipt", "whiteboard", "spreadsheet",
                          "chart", "page", "menu", "newspaper", "book"])
        let night = e.conf(["night", "dark", "firework", "city_lights", "dusk"])
        let build = e.conf(["building", "architecture", "skyscraper", "facade",
                            "tower", "bridge", "church", "city", "skyline", "roof"])
        let nature = e.conf(["landscape", "mountain", "beach", "sky", "sunset",
                             "sunrise", "sea", "ocean", "lake", "snow", "cloud",
                             "nature", "forest", "horizon", "coast", "field",
                             "valley", "river", "water"])
        let street = e.conf(["street", "road", "sidewalk", "traffic", "crowd",
                             "alley", "crosswalk", "plaza", "market"])
        let vehicle = e.conf(["vehicle", "car", "motorcycle", "bicycle", "bus",
                              "truck", "scooter", "train"])
        let indoor = e.conf(["indoor", "room", "interior", "furniture", "bedroom",
                             "living_room", "kitchen", "couch", "sofa", "table",
                             "desk", "shelf"])
        // 手工/玩具/艺术品：出现这些证据时，动物/建筑标签要打折
        let craft = e.conf(["toy", "doll", "craft", "handicraft", "bead",
                            "knit", "embroidery", "lego", "figurine", "art",
                            "sculpture", "model"])

        let humans = max(e.humanCount, e.faceCount)
        let humanStrong = e.humanCount >= 1 || (e.faceCount >= 1 && e.maxFaceArea >= 0.010)
        let textHeavy = e.textCoverage >= 0.06 && e.textLines >= 3
        let textDominant = e.textCoverage >= 0.18 && e.textLines >= 6
        /// 画面像屏幕渲染：色彩单一、对比平缓，或者文件本身就是 PNG
        let screenLike = e.isPNG || (e.colorfulness < 0.30 && e.contrast < 0.40)
        /// 一个居中的特写主体（手工、玩偶、拼豆都属于这种构图）
        let closeUp = e.saliencyArea >= 0.55
        /// 有相机拍摄的痕迹：有噪点、或者不是"像素级锐利"
        /// 截图/网图的锐度天然极高且几乎无噪点，照片很少这样
        let cameraLike = e.noise > 0.06 || e.sharpness < 0.55

        // =========================================================
        // 2. 屏幕内容（截图 / 网图 / 长图）
        // =========================================================
        // 关键：真截图靠元数据已经判掉了，剩下的是"存下来的网图/截图"，
        // 特征是满屏文字 + 没有动物没有人体 + 画面干净。
        if textDominant && animal < 0.40 && humans == 0 && food < 0.40 {
            if screenLike || !cameraLike {
                r("满屏文字（覆盖 \(pct(e.textCoverage))、\(e.textLines) 行），且画面接近屏幕渲染")
                return out(.screenshot, 0.80)
            }
        }

        // =========================================================
        // 3. 文档票据
        // =========================================================
        // 判"文档"必须同时满足：有文字 + 画面简单 + 没有动物/人体/食物主体。
        // 这样"一碗汤旁边有菜单"不会进文档，"演讲现场"也不会（有人）。
        let docShape = e.maxQuadArea >= 0.35 || textHeavy
        if (doc >= 0.40 || textHeavy) && animal < 0.40 && humans == 0
            && food < 0.40 && e.colorfulness < 0.42 && docShape {
            r("文档标签 \(f(doc))、文字覆盖 \(pct(e.textCoverage))、纸张/屏幕占比 \(pct(e.maxQuadArea))")
            return out(.document, doc >= 0.40 ? 0.85 : 0.65)
        }

        // =========================================================
        // 4. 人像
        // =========================================================
        // 先看人体检测：猫脸会被 VNDetectFaceRectangles 误检，
        // 但 VNDetectHumanRectangles 只认真人，玩偶/雕像基本不触发。
        // 所以"只有人脸、没有人体、又有动物证据"一律按宠物处理。
        let onlyFaceNoBody = e.humanCount == 0
        if humanStrong && animal < 0.55 && !(onlyFaceNoBody && animal >= 0.30) {
            r("人体 \(e.humanCount) 个 / 人脸 \(e.faceCount) 个（最大占 \(pct(e.maxFaceArea))）")
            return out(.portrait, e.humanCount >= 1 ? 0.85 : 0.70)
        }

        // =========================================================
        // 5. 宠物
        // =========================================================
        // 只认 VNRecognizeAnimals 的猫/狗结论。钩织企鹅、拼豆、玩偶
        // 拿不到这个结论，所以不会被塞进宠物。
        if animal >= 0.55 {
            r("动物识别：\(e.animalLabel.isEmpty ? "猫/狗" : e.animalLabel) \(f(animal))")
            return out(.pet, animal)
        }
        if animal >= 0.30 && craft < 0.35 && !closeUp {
            r("弱动物标签 \(f(animal))，且没有手工/玩具证据")
            return out(.pet, animal * 0.80)
        }

        // =========================================================
        // 6. 美食
        // =========================================================
        if food >= 0.45 && !textDominant {
            r("食物标签 \(f(food))、文字覆盖 \(pct(e.textCoverage))、色彩 \(pct(e.colorfulness))")
            return out(.food, food)
        }

        // =========================================================
        // 7. 夜景
        // =========================================================
        // 必须同时：暗 + 没有满屏文字（排除暗色截图）+ 有夜景或城市灯光证据。
        if e.brightness < 0.26 && !textHeavy && e.colorfulness < 0.45 {
            let evidence = night >= 0.30 || (build >= 0.30 && e.contrast > 0.18)
            if evidence {
                r("亮度 \(pct(e.brightness))、夜景标签 \(f(night))、对比 \(pct(e.contrast))")
                return out(.night, max(0.60, night))
            }
        }

        // =========================================================
        // 8. 建筑
        // =========================================================
        // 要"大尺度结构"：拼豆/手工作品虽然会拿到 building 标签，
        // 但显著主体占了绝大部分画面，属于特写，不是建筑。
        if build >= 0.45 && !closeUp && craft < 0.35
            && e.pixelRatio < 1.30 && e.contrast > 0.15 {
            r("建筑标签 \(f(build))、显著主体 \(pct(e.saliencyArea))、对比 \(pct(e.contrast))")
            return out(.architecture, build)
        }

        // =========================================================
        // 9. 风景
        // =========================================================
        if nature >= 0.45 && e.saliencyArea < 0.55 {
            r("自然类标签 \(f(nature))、显著主体 \(pct(e.saliencyArea))")
            return out(.landscape, nature)
        }

        // =========================================================
        // 10. 街拍
        // =========================================================
        // 要有街道场景，并且有车/人，不是"画面里有个车"。
        if street >= 0.40 && (vehicle >= 0.35 || humans >= 1) && !textHeavy {
            r("街道标签 \(f(street))、车辆 \(f(vehicle))、人体 \(e.humanCount)")
            return out(.street, street)
        }

        // =========================================================
        // 11. 静物 / 特写
        // =========================================================
        if closeUp || craft >= 0.30 || indoor >= 0.35 {
            r("显著主体 \(pct(e.saliencyArea))、手工/玩具 \(f(craft))、室内 \(f(indoor))")
            return out(.still, 0.55)
        }

        // =========================================================
        // 12. 兜底
        // =========================================================
        // 横构图 + 亮 + 有色彩：大概率是没被标签覆盖的风景
        if e.pixelRatio > 1.15 && e.brightness > 0.42 && e.colorfulness > 0.30 {
            r("横构图、亮度 \(pct(e.brightness))、色彩 \(pct(e.colorfulness))，无更具体标签")
            return out(.landscape, 0.35)
        }
        if e.saliencyArea > 0.30 {
            r("有显著主体但语义证据不足，先归入静物特写")
            return out(.still, 0.40)
        }
        r("证据不足，归入「其他」")
        return out(.other, 0.25)
    }

    // MARK: 格式化

    private static func pct(_ v: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, v)) * 100)
    }

    private static func f(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}
