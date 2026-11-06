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

    // MARK: - 主入口

    func analyze(image: UIImage,
                 assetInfo: AssetInfo,
                 includeOCR: Bool) -> PhotoRecord? {

        guard let cgImage = image.cgImage else { return nil }

        // 1) 基础统计（亮度 / 对比度 / 色彩 / 噪点）
        let stats = computeStats(cgImage: cgImage)

        // 2) 拉普拉斯锐度
        let sharp = computeSharpness(cgImage: cgImage)

        // 3) Vision 分类 + 人脸 + 指纹 + OCR
        let vision = runVision(cgImage: cgImage, includeOCR: includeOCR)

        let ratio = assetInfo.pixelHeight > 0
            ? Double(assetInfo.pixelWidth) / Double(assetInfo.pixelHeight)
            : 1.0

        // 4) 题材判定 —— 决定用哪套评分标准
        let (kind, kindConf) = KindClassifier.classify(
            isScreenshot: assetInfo.isScreenshot,
            categories: vision.categories,
            topIdentifier: vision.topIdentifier,
            faceCount: vision.faceCount,
            ocrText: vision.ocrText,
            brightness: stats.brightness,
            contrast: stats.contrast,
            colorfulness: stats.colorfulness,
            pixelRatio: ratio,
            sharpness: sharp
        )

        // 5) 按题材加权评分 + 问题检出
        let scored = KindScorer.score(
            kind: kind,
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
            kind: kind,
            kindConfidence: kindConf,
            issues: scored.issues,
            categories: cats,
            primaryCategory: primary,
            ocrText: vision.ocrText,
            faceCount: vision.faceCount,
            dhash: vision.dhash,
            analyzedAt: Date()
        )
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
                // 3x3 均值
                var sum = 0.0
                for dy in -1...1 {
                    for dx in -1...1 {
                        sum += luma[(y + dy) * w + (x + dx)]
                    }
                }
                let mean = sum / 9.0

                // 局部方差：太大说明是纹理/边缘，不是噪声，跳过
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
        // 取中位数，抗异常值
        let median = residuals[residuals.count / 2]

        // 经验映射：中位残差 0.002（干净）~ 0.030（很脏）
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
        var sq = response.map { $0 * $0 }
        vDSP_meanv(sq, 1, &meanSq, vDSP_Length(sq.count))
        let variance = max(0, meanSq - mean * mean)

        // 经验映射：variance 0.0002(糊) ~ 0.02(锐)
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
                var seen = Set<String>()
                // 置信度门槛提高到 0.20：
                // 0.12 时噪声标签太多（钩织企鹅 -> bird、玩偶 -> toy、菜单 -> document），
                // 这些弱标签会把题材判定带偏。0.20 只保留相对可信的标签。
                for obs in results where obs.confidence > 0.20 {
                    let label = obs.identifier
                    let zh = CategoryMap.zh(for: label)
                    if zh == "其他" { continue }
                    if seen.contains(zh) { continue }
                    seen.insert(zh)
                    cats.append(CategoryHit(label: label, zh: zh, confidence: Double(obs.confidence)))
                    if topID.isEmpty { topID = label }
                    if cats.count >= 5 { break }
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

    // MARK: - 工具

    private func clamp01(_ v: Double) -> Double {
        if v.isNaN { return 0 }
        return min(1, max(0, v))
    }
}
