import Foundation
import UIKit

/// 诊断导出。
///
/// 目的只有一个：当自动分类判错时，能拿到"这台手机、这张照片"的真实测量值，
/// 而不是靠猜。导出内容不含照片、不含 OCR 原文，只有数值和 Vision 标签。
enum Diagnostics {

    // MARK: 结构

    struct Row: Codable {
        let id: String
        let kind: String
        let manual: String?
        let conf: Double
        let screenshot: Bool
        let png: Bool
        let w: Int
        let h: Int
        let mp: Double
        let animal: Double
        let animalLabel: String
        let faces: Int
        let faceArea: Double
        let humans: Int
        let textCov: Double
        let textLines: Int
        let quad: Double
        let saliency: Double
        let brightness: Double
        let contrast: Double
        let colorfulness: Double
        let sharpness: Double
        let noise: Double
        let labels: [LabelScore]
        let reasons: [String]
    }

    struct Bundle: Codable {
        let appVersion: String
        let analyzerVersion: Int
        let generatedAt: String
        let device: String
        let total: Int
        let scored: Int
        let byKind: [String: Int]
        let manualOverrides: Int
        let withEvidence: Int
        let rows: [Row]
    }

    // MARK: 版本信息

    static var appVersion: String {
        let info = Foundation.Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    static var deviceInfo: String {
        "\(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)"
    }

    // MARK: 组装

    static func makeBundle(_ records: [PhotoRecord]) -> Bundle {
        var byKind: [String: Int] = [:]
        for r in records { byKind[r.effectiveKind.rawValue, default: 0] += 1 }

        let rows: [Row] = records.map { r in
            let f = r.feats ?? FeatureSnapshot()
            return Row(
                id: r.id,
                kind: r.effectiveKind.rawValue,
                manual: r.manualKind?.rawValue,
                conf: round(r.kindConfidence * 1000) / 1000,
                screenshot: r.isScreenshot,
                png: f.png,
                w: r.pixelWidth,
                h: r.pixelHeight,
                mp: round(r.megapixels * 10) / 10,
                animal: f.animal,
                animalLabel: f.animalLabel,
                faces: f.faces,
                faceArea: f.faceArea,
                humans: f.humans,
                textCov: f.textCoverage,
                textLines: f.textLines,
                quad: f.quad,
                saliency: f.saliency,
                brightness: r.exposure,
                contrast: r.contrast,
                colorfulness: r.colorfulness,
                sharpness: r.sharpness,
                noise: r.noise,
                labels: f.labels,
                reasons: r.kindEvidence ?? []
            )
        }

        let fmt = ISO8601DateFormatter()
        return Bundle(
            appVersion: appVersion,
            analyzerVersion: AnalyzerVersion.current,
            generatedAt: fmt.string(from: Date()),
            device: deviceInfo,
            total: records.count,
            scored: records.filter { $0.isScored }.count,
            byKind: byKind,
            manualOverrides: records.filter { $0.manualKind != nil }.count,
            withEvidence: records.filter { $0.feats != nil }.count,
            rows: rows
        )
    }

    // MARK: 落盘

    static func writeFile(_ records: [PhotoRecord]) -> URL? {
        let bundle = makeBundle(records)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(bundle) else { return nil }

        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photosweep-diagnostic-\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: 单张文本（复制到剪贴板）

    static func text(for r: PhotoRecord) -> String {
        let f = r.feats
        var lines: [String] = []
        lines.append("版本 \(appVersion) · 规则 v\(AnalyzerVersion.current) · \(deviceInfo)")
        lines.append("判定 \(r.kind.rawValue)（\(Int(r.kindConfidence * 100))%）"
                     + (r.manualKind.map { " · 手动改为 \($0.rawValue)" } ?? ""))
        lines.append("尺寸 \(r.pixelWidth)x\(r.pixelHeight)  px=\(r.isScreenshot) png=\(f?.png ?? false)")
        if let f {
            lines.append("动物 \(String(format: "%.2f", f.animal)) \(f.animalLabel)｜人脸 \(f.faces)（\(String(format: "%.1f%%", f.faceArea * 100))）｜人体 \(f.humans)")
            lines.append("文字覆盖 \(String(format: "%.1f%%", f.textCoverage * 100))（\(f.textLines) 行）｜纸/屏 \(String(format: "%.0f%%", f.quad * 100))｜显著主体 \(String(format: "%.0f%%", f.saliency * 100))")
            lines.append("亮度 \(String(format: "%.2f", r.exposure))｜对比 \(String(format: "%.2f", r.contrast))｜色彩 \(String(format: "%.2f", r.colorfulness))｜锐度 \(String(format: "%.2f", r.sharpness))｜噪点 \(String(format: "%.2f", r.noise))")
            lines.append("标签 " + f.labels.prefix(8).map { "\($0.id):\(String(format: "%.2f", $0.conf))" }.joined(separator: ", "))
        } else {
            lines.append("（这条是旧版本算的，没有测量值）")
        }
        lines.append("依据 " + (r.kindEvidence ?? []).joined(separator: " / "))
        return lines.joined(separator: "\n")
    }
}
