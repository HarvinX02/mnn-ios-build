import Foundation
import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import Accelerate

/// 单张照片的完整分析器。
/// 全部在本机完成：CoreImage 做基础统计，vImage 做拉普拉斯锐度，
/// Vision 负责分类 / OCR / 人脸 / 特征指纹。
final class PhotoAnalyzer {

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // 分析用的工作尺寸。太大慢，太小锐度判断失真。
    private let workSize = CGSize(width: 512, height: 512)

    // MARK: - 主入口

    /// 分析一张图。返回 nil 表示无法解码。
    func analyze(image: UIImage,
                 assetInfo: AssetInfo,
                 includeOCR: Bool) -> PhotoRecord? {

        guard let cgImage = image.cgImage else { return nil }

        // 1) 基础统计（亮度 / 对比度 / 色彩丰富度）
        let stats = computeStats(cgImage: cgImage)

        // 2) 拉普拉斯锐度
        let sharp = computeSharpness(cgImage: cgImage)

        // 3) Vision 分类 + 人脸 + 指纹
        let vision = runVision(cgImage: cgImage, includeOCR: includeOCR)

        // 4) 综合评分
        let score = combineScore(
            sharpness: sharp,
            exposure: stats.brightness,
            contrast: stats.contrast,
            colorfulness: stats.colorfulness,
            megapixels: assetInfo.megapixels,
            isScreenshot: assetInfo.isScreenshot
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
            qualityScore: score,
            grade: QualityGrade.from(score: score),
            categories: cats,
            primaryCategory: primary,
            ocrText: vision.ocrText,
            faceCount: vision.faceCount,
            dhash: vision.dhash,
            analyzedAt: Date()
        )
    }

    // MARK: - 亮度 / 对比度 / 色彩

    private struct Stats {
        var brightness: Double
        var contrast: Double
        var colorfulness: Double
    }

    private func computeStats(cgImage: CGImage) -> Stats {
        // 缩到 64x64 做直方图统计即可
        let w = 64, h = 64
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return Stats(brightness: 0.5, contrast: 0.5, colorfulness: 0.5)
        }
        ctx.interpolationQuality = .low
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

        // 亮度均值
        var mean = 0.0
        vDSP_meanvD(luma, 1, &mean, vDSP_Length(luma.count))

        // 亮度标准差 = 对比度
        var meanSq = 0.0
        var sq = luma.map { $0 * $0 }
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
        var rgSq = rg.map { $0 * $0 }, ybSq = yb.map { $0 * $0 }
        vDSP_meanvD(rgSq, 1, &rgS, vDSP_Length(rgSq.count))
        vDSP_meanvD(ybSq, 1, &ybS, vDSP_Length(ybSq.count))
        let rgStd = sqrt(max(0, rgS - rgM * rgM))
        let ybStd = sqrt(max(0, ybS - ybM * ybM))
        let colorful = sqrt(rgStd * rgStd + ybStd * ybStd) + 0.3 * sqrt(rgM * rgM + ybM * ybM)

        return Stats(
            brightness: clamp01(mean),
            contrast: clamp01(std * 2.2),          // 经验系数
            colorfulness: clamp01(colorful * 2.4)
        )
    }

    // MARK: - 拉普拉斯锐度

    /// 对灰度图做 3x3 拉普拉斯卷积，取方差。方差越大越锐利。
    /// 这是判断"糊没糊"的工业标准做法，比任何 VLM 都准且快。
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

        // 拉普拉斯核
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
        var sq = response.map { $0 * $0 }
        vDSP_meanv(sq, 1, &meanSq, vDSP_Length(sq.count))
        let variance = max(0, meanSq - mean * mean)

        // 经验映射：variance 0.0002(糊) ~ 0.02(锐)
        // 用对数刻度更符合人眼感受
        let v = Double(variance)
        let normalized = log10(1 + v * 5000) / log10(1 + 120)
        return clamp01(normalized)
    }

    // MARK: - Vision

    private struct VisionOut {
        var categories: [CategoryHit]
        var topIdentifier: String
        var ocrText: String
        var faceCount: Int
        var dhash: UInt64
    }

    private func runVision(cgImage: CGImage, includeOCR: Bool) -> VisionOut {
        var cats: [CategoryHit] = []
        var topID = ""
        var ocr = ""
        var faces = 0
        var hash: UInt64 = 0

        // --- 分类 ---
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([classify])
            if let results = classify.results {
                // 取置信度最高的若干项，按中文去重
                var seen = Set<String>()
                for obs in results where obs.confidence > 0.12 {
                    let label = obs.identifier
                    let zh = CategoryMap.zh(for: label)
                    if zh == "其他" { continue }
                    if seen.contains(zh) { continue }
                    seen.insert(zh)
                    cats.append(CategoryHit(label: label, zh: zh, confidence: Double(obs.confidence)))
                    if topID.isEmpty { topID = label }
                    if cats.count >= 4 { break }
                }
            }
        } catch { }

        // --- OCR ---
        if includeOCR {
            let ocrReq = VNRecognizeTextRequest()
            ocrReq.recognitionLevel = .accurate
            ocrReq.usesLanguageCorrection = false
            ocrReq.recognitionLanguages = ["zh-Hans", "en-US"]
            let h2 = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try h2.perform([ocrReq])
                if let obs = ocrReq.results {
                    let lines = obs.compactMap { $0.topCandidates(1).first?.string }
                    ocr = lines.joined(separator: " ")
                    if ocr.count > 300 { ocr = String(ocr.prefix(300)) }
                }
            } catch { }
        }

        // --- 人脸 ---
        let faceReq = VNDetectFaceRectanglesRequest()
        let h3 = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try h3.perform([faceReq])
            faces = faceReq.results?.count ?? 0
        } catch { }

        // --- 特征指纹（用于找相似/连拍） ---
        let feat = VNGenerateImageFeaturePrintRequest()
        let h4 = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try h4.perform([feat])
            if let r = feat.results?.first {
                hash = Self.foldFeaturePrint(r)
            }
        } catch { }

        return VisionOut(categories: cats, topIdentifier: topID,
                         ocrText: ocr, faceCount: faces, dhash: hash)
    }

    /// 把 featurePrint 的浮点向量压成一个 64 位摘要，供快速近似比较。
    /// 注意：这是粗筛手段，精确相似度仍应使用 VNFeaturePrintObservation.computeDistance。
    private static func foldFeaturePrint(_ obs: VNFeaturePrintObservation) -> UInt64 {
        let data = obs.data
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return 0 }
        var acc: UInt64 = 0xcbf29ce484222325
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<count {
                let v = floats[i]
                let bits = v.bitPattern
                acc = (acc ^ UInt64(bits)) &* 0x100000001b3
            }
        }
        return acc
    }

    // MARK: - 综合评分

    /// 权重设计：
    ///   锐度 45%（最影响观感）
    ///   曝光 20%（过曝/欠曝）
    ///   对比 12%
    ///   色彩 13%
    ///   分辨率 10%
    /// 截图额外降分（一般不需要保留）
    private func combineScore(sharpness: Double,
                              exposure: Double,
                              contrast: Double,
                              colorfulness: Double,
                              megapixels: Double,
                              isScreenshot: Bool) -> Double {
        // 曝光最优区间 0.35~0.7，两端衰减
        let expScore: Double
        if exposure < 0.35 {
            expScore = exposure / 0.35
        } else if exposure > 0.7 {
            expScore = max(0, 1 - (exposure - 0.7) / 0.3)
        } else {
            expScore = 1.0
        }

        let mpScore = min(1.0, megapixels / 12.0)

        var s = sharpness * 0.45
              + expScore * 0.20
              + contrast * 0.12
              + colorfulness * 0.13
              + mpScore * 0.10

        if isScreenshot { s *= 0.55 }
        return clamp01(s)
    }

    // MARK: - 工具

    private func clamp01(_ v: Double) -> Double {
        if v.isNaN { return 0 }
        return min(1, max(0, v))
    }
}
