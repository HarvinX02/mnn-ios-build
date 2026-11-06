import Foundation
import UIKit
import Vision
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import Accelerate

/// 单张照片的完整分析器。
/// 全部在本机完成：CoreImage 做基础统计，vImage 做拉普拉斯锐度，
/// Vision 负责分类 / 动物 / 人体 / 人脸 / OCR / 纸张 / 显著主体 / 特征指纹。
final class PhotoAnalyzer {

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - 主入口

    func analyze(image: UIImage,
                 assetInfo: AssetInfo,
                 includeOCR: Bool) -> PhotoRecord? {

        guard let cgImage = image.cgImage else { return nil }

        // 1) 基础统计（亮度 / 对比度 / 色彩 / 噪点）
        let stats = computeStats(cgImage: cgImage)

        // 2) 拉普拉斯锐度
        let sharp = computeSharpness(cgImage: cgImage)

        // 3) Vision 多源特征
        let vision = runVision(cgImage: cgImage,
                               orientation: Self.cgOrientation(image.imageOrientation),
                               includeOCR: includeOCR)

        let ratio = assetInfo.pixelHeight > 0
            ? Double(assetInfo.pixelWidth) / Double(assetInfo.pixelHeight)
            : 1.0

        // 4) 组装证据集
        var ev = PhotoEvidence()
        ev.isScreenshot = assetInfo.isScreenshot
        ev.isPanorama = assetInfo.isPanorama
        ev.isPNG = assetInfo.isPNG
        ev.isLivePhoto = assetInfo.isLivePhoto
        ev.pixelRatio = ratio
        ev.brightness = stats.brightness
        ev.contrast = stats.contrast
        ev.colorfulness = stats.colorfulness
        ev.sharpness = sharp
        ev.noise = stats.noise
        ev.labels = vision.allLabels
        ev.animalConf = vision.animalConf
        ev.animalLabel = vision.animalLabel
        ev.faceCount = vision.faceCount
        ev.maxFaceArea = vision.maxFaceArea
        ev.humanCount = vision.humanCount
        ev.maxHumanArea = vision.maxHumanArea
        ev.textCoverage = vision.textCoverage
        ev.textLines = vision.textLines
        ev.textHeightRatio = vision.textHeightRatio
        ev.maxQuadArea = vision.maxQuadArea
        ev.saliencyArea = vision.saliencyArea

        // 5) 题材判定
        let verdict = EvidenceClassifier.classify(ev)

        // 6) 按题材加权评分 + 问题检出
        let scored = KindScorer.score(
            kind: verdict.kind,
            sharpness: sharp,
            brightness: stats.brightness,
            contrast: stats.contrast,
            colorfulness: stats.colorfulness,
            noise: stats.noise,
            megapixels: assetInfo.megapixels
        )

        let cats = vision.categories
        let primary = cats.first?.zh ?? CategoryMap.zh(for: vision.topIdentifier)

        return PhotoRecord(
            id: assetInfo.id,
            creationDate: assetInfo.creationDate,
            pixelWidth: assetInfo.pixelWidth,
            pixelHeight: assetInfo.pixelHeight,
            fileSize: assetInfo.fileSize,
            isScreenshot: assetInfo.isScreenshot,
            isVideo: assetInfo.isVideo,
            sharpness: sharp,
            exposure: stats.brightness,
            contrast: stats.contrast,
            colorfulness: stats.colorfulness,
            noise: stats.noise,
            tiltDegrees: 0,
            qualityScore: scored.score,
            grade: QualityGrade.from(score: scored.score),
            kind: verdict.kind,
            kindConfidence: verdict.confidence,
            issues: scored.issues,
            categories: cats,
            primaryCategory: primary,
            ocrText: vision.ocrText,
            faceCount: vision.faceCount,
            dhash: vision.dhash,
            analyzedAt: Date(),
            kindEvidence: verdict.reasons + Self.extraEvidence(ev),
            analyzerVersion: AnalyzerVersion.current
        )
    }

    /// 补充展示用证据（阈值判断之外，也让用户看到测量值本身）
    private static func extraEvidence(_ e: PhotoEvidence) -> [String] {
        var rows: [String] = []
        rows.append("标签：\(e.topLabelsText.isEmpty ? "无" : e.topLabelsText)")
        rows.append("动物 \(String(format: "%.2f", e.animalConf))、人体 \(e.humanCount)、"
                    + "人脸 \(e.faceCount)、文字覆盖 \(String(format: "%.0f%%", e.textCoverage * 100))")
        rows.append("显著主体 \(String(format: "%.0f%%", e.saliencyArea * 100))、"
                    + "纸/屏 \(String(format: "%.0f%%", e.maxQuadArea * 100))、"
                    + "噪点 \(String(format: "%.2f", e.noise))")
        return rows
    }

    // MARK: - 亮度 / 对比度 / 色彩 / 噪点

    private struct Stats {
        var brightness: Double
        var contrast: Double
        var colorfulness: Double
        var noise: Double
    }

    private func computeStats(cgImage: CGImage) -> Stats {
        let w = 96, h = 96
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return Stats(brightness: 0.5, contrast: 0.5, colorfulness: 0.5, noise: 0.1)
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var luma = [Double](repeating: 0, count: w * h)
        var rs = [Double](repeating: 0, count: w * h)
        var gs = [Double](repeating: 0, count: w * h)
        var bs = [Double](repeating: 0, count: w * h)

        for i in 0..<(w * h) {
            let r = Double(buf[i * 4 + 0]) / 255.0
            let g = Double(buf[i * 4 + 1]) / 255.0
            let b = Double(buf[i * 4 + 2]) / 255.0
            rs[i] = r; gs[i] = g; bs[i] = b
            luma[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }

        var mean = 0.0
        vDSP_meanvD(luma, 1, &mean, vDSP_Length(luma.count))

        var meanSq = 0.0
        let sq = luma.map { $0 * $0 }
        vDSP_meanvD(sq, 1, &meanSq, vDSP_Length(sq.count))
        let std = sqrt(max(0, meanSq - mean * mean))

        // Hasler-Süsstrunk 色彩丰富度
        var rg = [Double](repeating: 0, count: w * h)
        var yb = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            rg[i] = rs[i] - gs[i]
            yb[i] = 0.5 * (rs[i] + gs[i]) - bs[i]
        }
        var rgM = 0.0, ybM = 0.0
        vDSP_meanvD(rg, 1, &rgM, vDSP_Length(rg.count))
        vDSP_meanvD(yb, 1, &ybM, vDSP_Length(yb.count))
        var rgS = 0.0, ybS = 0.0
        let rgSq = rg.map { $0 * $0 }, ybSq = yb.map { $0 * $0 }
        vDSP_meanvD(rgSq, 1, &rgS, vDSP_Length(rgSq.count))
        vDSP_meanvD(ybSq, 1, &ybS, vDSP_Length(ybSq.count))
        let rgStd = sqrt(max(0, rgS - rgM * rgM))
        let ybStd = sqrt(max(0, ybS - ybM * ybM))
        let colorful = sqrt(rgStd * rgStd + ybStd * ybStd) + 0.3 * sqrt(rgM * rgM + ybM * ybM)

        // 噪点估计：用"高频残差"近似。
        // 做法：3x3 均值滤波后与原图求差，平坦区域（本身没有结构）的差值就近似噪声。
        let noise = estimateNoise(luma: luma, w: w, h: h)

        return Stats(
            brightness: clamp01(mean),
            contrast: clamp01(std * 2.2),
            colorfulness: clamp01(colorful * 2.4),
            noise: noise
        )
    }

    /// 高通残差法估噪点。
    /// 只在"局部本身很平坦"的块上统计，避免把真实纹理当成噪声。
    private func estimateNoise(luma: [Double], w: Int, h: Int) -> Double {
        var residuals: [Double] = []
        residuals.reserveCapacity((w - 2) * (h - 2) / 4)

        for y in stride(from: 1, to: h - 1, by: 2) {
            for x in stride(from: 1, to: w - 1, by: 2) {
                var sum = 0.0
                for dy in -1...1 {
                    for dx in -1...1 {
                        sum += luma[(y + dy) * w + (x + dx)]
                    }
                }
                let mean = sum / 9.0

                var varSum = 0.0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let d = luma[(y + dy) * w + (x + dx)] - mean
                        varSum += d * d
                    }
                }
                let localVar = varSum / 9.0
                if localVar > 0.0009 { continue }   // 有结构，不计入

                let center = luma[y * w + x]
                residuals.append(abs(center - mean))
            }
        }

        guard residuals.count > 40 else { return 0.05 }

        residuals.sort()
        let median = residuals[residuals.count / 2]
        let v = log10(1 + median * 1000) / log10(1 + 30)
        return clamp01(v)
    }

    // MARK: - 拉普拉斯锐度

    /// 对灰度图做 3x3 拉普拉斯卷积，取方差。方差越大越锐利。
    private func computeSharpness(cgImage: CGImage) -> Double {
        let w = 256, h = 256
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &gray,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0.5 }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var src = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { src[i] = Float(gray[i]) / 255.0 }

        let kernel: [Float] = [0, 1, 0,
                               1, -4, 1,
                               0, 1, 0]

        var response = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var acc: Float = 0
                var k = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        acc += src[(y + dy) * w + (x + dx)] * kernel[k]
                        k += 1
                    }
                }
                response[y * w + x] = acc
            }
        }

        var mean: Float = 0
        vDSP_meanv(response, 1, &mean, vDSP_Length(response.count))
        var meanSq: Float = 0
        let sq = response.map { $0 * $0 }
        vDSP_meanv(sq, 1, &meanSq, vDSP_Length(sq.count))
        let variance = max(0, meanSq - mean * mean)

        let v = Double(variance)
        let normalized = log10(1 + v * 5000) / log10(1 + 120)
        return clamp01(normalized)
    }

    // MARK: - Vision 多源特征

    private struct VisionOut {
        var categories: [CategoryHit]
        var allLabels: [(id: String, conf: Double)]
        var topIdentifier: String
        var ocrText: String
        var textCoverage: Double
        var textLines: Int
        var textHeightRatio: Double
        var faceCount: Int
        var maxFaceArea: Double
        var humanCount: Int
        var maxHumanArea: Double
        var animalConf: Double
        var animalLabel: String
        var maxQuadArea: Double
        var saliencyArea: Double
        var dhash: UInt64
    }

    private func runVision(cgImage: CGImage,
                           orientation: CGImagePropertyOrientation,
                           includeOCR: Bool) -> VisionOut {

        var cats: [CategoryHit] = []
        var allLabels: [(id: String, conf: Double)] = []
        var topID = ""
        var ocr = ""
        var textCoverage = 0.0
        var textLines = 0
        var textHeight = 0.0
        var faces = 0
        var maxFaceArea = 0.0
        var humans = 0
        var maxHumanArea = 0.0
        var animalConf = 0.0
        var animalLabel = ""
        var maxQuadArea = 0.0
        var saliencyArea = 0.0
        var hash: UInt64 = 0

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])

        // --- 1) 图像分类（保留全部中等以上标签，作为证据而不是结论）---
        let classify = VNClassifyImageRequest()
        do {
            try handler.perform([classify])
            if let results = classify.results {
                // 全部标签（证据用，门槛放很低）
                for obs in results where obs.confidence > 0.08 {
                    allLabels.append((id: obs.identifier, conf: Double(obs.confidence)))
                    if allLabels.count >= 24 { break }
                }
                // 展示用的分类（门槛高一些，并按中文去重）
                var seen = Set<String>()
                for l in allLabels where l.conf > 0.18 {
                    let zh = CategoryMap.zh(for: l.id)
                    if zh == "其他" { continue }
                    if seen.contains(zh) { continue }
                    seen.insert(zh)
                    cats.append(CategoryHit(label: l.id, zh: zh, confidence: l.conf))
                    if cats.count >= 5 { break }
                }
                if let top = allLabels.first { topID = top.id }
            }
        } catch { }

        // --- 2) 动物识别：只认猫/狗，是"宠物"最可靠的证据 ---
        let animalReq = VNRecognizeAnimalsRequest()
        do {
            try handler.perform([animalReq])
            if let results = animalReq.results {
                for obs in results {
                    guard let best = obs.labels.first else { continue }
                    let conf = Double(best.confidence)
                    if conf > animalConf {
                        animalConf = conf
                        animalLabel = best.identifier
                    }
                }
            }
        } catch { }

        // --- 3) 人脸（可能把猫/玩偶误检，所以只作辅助证据）---
        let faceReq = VNDetectFaceRectanglesRequest()
        do {
            try handler.perform([faceReq])
            if let results = faceReq.results {
                faces = results.count
                for f in results {
                    let a = Double(f.boundingBox.width * f.boundingBox.height)
                    if a > maxFaceArea { maxFaceArea = a }
                }
            }
        } catch { }

        // --- 4) 人体（真人检测，玩偶/雕像基本不触发）---
        let humanReq = VNDetectHumanRectanglesRequest()
        do {
            try handler.perform([humanReq])
            if let results = humanReq.results {
                humans = results.count
                for hb in results {
                    let a = Double(hb.boundingBox.width * hb.boundingBox.height)
                    if a > maxHumanArea { maxHumanArea = a }
                }
            }
        } catch { }

        // --- 5) OCR：除了文字内容，还要"文字占多大面积"---
        //     这是区分"文档/截图"和"照片里有块招牌"的关键。
        if includeOCR {
            let ocrReq = VNRecognizeTextRequest()
            ocrReq.recognitionLevel = .accurate
            ocrReq.usesLanguageCorrection = false
            ocrReq.recognitionLanguages = ["zh-Hans", "en-US"]
            do {
                try handler.perform([ocrReq])
                if let obs = ocrReq.results {
                    let lines = obs.compactMap { $0.topCandidates(1).first?.string }
                    ocr = lines.joined(separator: " ")
                    if ocr.count > 400 { ocr = String(ocr.prefix(400)) }

                    textLines = obs.count
                    var area = 0.0
                    var hSum = 0.0
                    for o in obs {
                        let bb = o.boundingBox
                        area += Double(bb.width * bb.height)
                        hSum += Double(bb.height)
                    }
                    textCoverage = min(1.0, area)
                    if !obs.isEmpty { textHeight = hSum / Double(obs.count) }
                }
            } catch { }
        }

        // --- 6) 纸张/屏幕四边形：整块纸、整块屏幕 ---
        let rectReq = VNDetectRectanglesRequest()
        rectReq.maximumObservations = 5
        rectReq.minimumConfidence = 0.35
        rectReq.minimumSize = 0.15
        rectReq.minimumAspectRatio = 0.1
        rectReq.quadratureTolerance = 40
        do {
            try handler.perform([rectReq])
            if let results = rectReq.results {
                for q in results {
                    let a = Double(q.boundingBox.width * q.boundingBox.height)
                    if a > maxQuadArea { maxQuadArea = a }
                }
            }
        } catch { }

        // --- 7) 显著主体：判断是不是"一个居中的特写"---
        let salReq = VNGenerateAttentionBasedSaliencyImageRequest()
        do {
            try handler.perform([salReq])
            if let obs = salReq.results?.first,
               let objects = obs.salientObjects {
                var area = 0.0
                for o in objects {
                    area += Double(o.boundingBox.width * o.boundingBox.height)
                }
                saliencyArea = min(1.0, area)
            }
        } catch { }

        // --- 8) 特征指纹（用于找相似/连拍）---
        let feat = VNGenerateImageFeaturePrintRequest()
        do {
            try handler.perform([feat])
            if let r = feat.results?.first {
                hash = Self.foldFeaturePrint(r)
            }
        } catch { }

        return VisionOut(
            categories: cats,
            allLabels: allLabels,
            topIdentifier: topID,
            ocrText: ocr,
            textCoverage: textCoverage,
            textLines: textLines,
            textHeightRatio: textHeight,
            faceCount: faces,
            maxFaceArea: maxFaceArea,
            humanCount: humans,
            maxHumanArea: maxHumanArea,
            animalConf: animalConf,
            animalLabel: animalLabel,
            maxQuadArea: maxQuadArea,
            saliencyArea: saliencyArea,
            dhash: hash
        )
    }

    /// 把 featurePrint 的浮点向量压成一个 64 位摘要，供快速近似比较。
    private static func foldFeaturePrint(_ obs: VNFeaturePrintObservation) -> UInt64 {
        let data = obs.data
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return 0 }
        var acc: UInt64 = 0xcbf29ce484222325
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<count {
                let bits = floats[i].bitPattern
                acc = (acc ^ UInt64(bits)) &* 0x100000001b3
            }
        }
        return acc
    }

    /// UIImage 的朝向 -> Vision 需要的 CGImagePropertyOrientation。
    /// 之前直接用 cgImage 分析，竖拍照片在 Vision 里是躺倒的，OCR 基本失效。
    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    // MARK: - 工具

    private func clamp01(_ v: Double) -> Double {
        if v.isNaN { return 0 }
        return min(1, max(0, v))
    }
}
