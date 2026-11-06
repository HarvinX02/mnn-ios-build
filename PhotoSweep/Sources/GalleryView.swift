import SwiftUI
import Photos

// MARK: - 缩略图缓存

final class ThumbCache {
    static let shared = ThumbCache()
    private var cache: [String: UIImage] = [:]
    private let lock = NSLock()
    private let mgr = PHCachingImageManager()

    func image(for id: String, size: CGFloat = 200) -> UIImage? {
        lock.lock()
        let hit = cache[id]
        lock.unlock()
        if let hit { return hit }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }

        let opt = PHImageRequestOptions()
        opt.isSynchronous = true
        opt.deliveryMode = .fastFormat
        opt.resizeMode = .fast

        var out: UIImage?
        mgr.requestImage(for: asset,
                         targetSize: CGSize(width: size, height: size),
                         contentMode: .aspectFill,
                         options: opt) { img, _ in out = img }

        if let out {
            lock.lock(); cache[id] = out; lock.unlock()
        }
        return out
    }
}

struct ThumbView: View {
    let id: String
    var size: CGFloat = 200
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.tertiarySystemFill))
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView().scaleEffect(0.6)
            }
        }
        .clipped()
        .task(id: id) {
            let key = id
            let s = size
            let loaded = await Task.detached(priority: .userInitiated) {
                ThumbCache.shared.image(for: key, size: s)
            }.value
            if img == nil { img = loaded }
        }
    }
}

// MARK: - 图库页

struct GalleryView: View {
    @EnvironmentObject var scanner: LibraryScanner

    @State private var sort: SortKey = .worst
    @State private var gradeFilter: QualityGrade? = nil
    @State private var categoryFilter: String? = nil
    @State private var search = ""
    @State private var onlyScreenshots = false
    @State private var selection = Set<String>()
    @State private var selecting = false
    @State private var showDeleteConfirm = false

    private var filtered: [PhotoRecord] {
        var list = scanner.records

        if let g = gradeFilter {
            list = list.filter { $0.grade == g }
        }
        if let c = categoryFilter {
            list = list.filter { $0.primaryCategory == c }
        }
        if onlyScreenshots {
            list = list.filter { $0.isScreenshot }
        }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter { $0.searchBlob.contains(q) }
        }

        switch sort {
        case .worst:   list.sort { $0.qualityScore < $1.qualityScore }
        case .best:    list.sort { $0.qualityScore > $1.qualityScore }
        case .newest:  list.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .oldest:  list.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        case .largest: list.sort { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        }
        return list
    }

    private var allCategories: [String] {
        var set = Set<String>()
        for r in scanner.records { set.insert(r.primaryCategory) }
        return set.sorted()
    }

    private let cols = [GridItem(.adaptive(minimum: 108), spacing: 4)]

    var body: some View {
        NavigationStack {
            Group {
                if scanner.records.isEmpty {
                    ContentUnavailableView("还没有分析结果",
                                           systemImage: "photo.on.rectangle.angled",
                                           description: Text("先到「扫描」页跑一次相册分析"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: 4) {
                            ForEach(filtered) { rec in
                                cell(rec)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            .navigationTitle("图库 (\(filtered.count))")
            .searchable(text: $search, prompt: "搜分类、文字内容、质量")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("排序") {
                            Picker("排序", selection: $sort) {
                                ForEach(SortKey.allCases) { k in
                                    Text(k.rawValue).tag(k)
                                }
                            }
                        }
                        Section("质量") {
                            Picker("质量", selection: $gradeFilter) {
                                Text("全部").tag(QualityGrade?.none)
                                ForEach(QualityGrade.allCases) { g in
                                    Text(g.rawValue).tag(QualityGrade?.some(g))
                                }
                            }
                        }
                        Section("分类") {
                            Picker("分类", selection: $categoryFilter) {
                                Text("全部").tag(String?.none)
                                ForEach(allCategories, id: \.self) { c in
                                    Text(c).tag(String?.some(c))
                                }
                            }
                        }
                        Toggle("只看截图", isOn: $onlyScreenshots)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "完成" : "选择") {
                        selecting.toggle()
                        if !selecting { selection.removeAll() }
                    }
                }
                if selecting {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("删除 \(selection.count) 张", systemImage: "trash")
                        }
                        .disabled(selection.isEmpty)
                    }
                }
            }
            .confirmationDialog("确认删除 \(selection.count) 张照片？",
                                isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    let ids = Array(selection)
                    selection.removeAll()
                    selecting = false
                    Task { try? await scanner.delete(ids: ids) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会从系统相册中移除，iCloud 端也会同步删除。")
            }
        }
    }

    private func cell(_ rec: PhotoRecord) -> some View {
        let isSel = selection.contains(rec.id)
        return ZStack(alignment: .topTrailing) {
            NavigationLink {
                DetailView(record: rec)
            } label: {
                ThumbView(id: rec.id)
                    .aspectRatio(1, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .bottomLeading) {
                        gradeBadge(rec)
                    }
                    .overlay {
                        if isSel {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(selecting)

            if selecting {
                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSel ? Color.accentColor : .white)
                    .padding(4)
                    .onTapGesture {
                        if isSel { selection.remove(rec.id) }
                        else { selection.insert(rec.id) }
                    }
            }
        }
    }

    private func gradeBadge(_ rec: PhotoRecord) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(badgeColor(rec.grade))
                .frame(width: 6, height: 6)
            Text(String(format: "%.0f", rec.qualityScore * 100))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(4)
    }

    private func badgeColor(_ g: QualityGrade) -> Color {
        switch g {
        case .excellent: return .green
        case .good: return .blue
        case .fair: return .orange
        case .poor: return .red
        }
    }
}

// MARK: - 详情页

struct DetailView: View {
    let record: PhotoRecord
    @State private var img: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Color(.secondarySystemBackground)
                    if let img {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                scoreBlock
                metricsBlock
                categoryBlock
                if !record.ocrText.isEmpty { ocrBlock }
                metaBlock
            }
            .padding()
        }
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let id = record.id
            let loaded = await Task.detached {
                ThumbCache.shared.image(for: id, size: 1200)
            }.value
            img = loaded
        }
    }

    private var scoreBlock: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color(.tertiarySystemFill), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(record.qualityScore))
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(String(format: "%.0f", record.qualityScore * 100))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                    Text("分")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 4) {
                Label(record.grade.rawValue, systemImage: record.grade.symbol)
                    .font(.headline)
                    .foregroundStyle(scoreColor)
                Text("\(record.primaryCategory) · \(record.aspectLabel)幅")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if record.isScreenshot {
                    Text("截图").font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
            }
            Spacer()
        }
    }

    private var scoreColor: Color {
        switch record.grade {
        case .excellent: return .green
        case .good: return .blue
        case .fair: return .orange
        case .poor: return .red
        }
    }

    private var metricsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("画质指标").font(.headline)
            metric("清晰度", record.sharpness)
            metric("曝光", record.exposure)
            metric("对比度", record.contrast)
            metric("色彩", record.colorfulness)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(_ name: String, _ v: Double) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.subheadline)
                .frame(width: 48, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(barColor(v))
                        .frame(width: geo.size.width * CGFloat(min(1, v)))
                }
            }
            .frame(height: 7)
            Text(String(format: "%.2f", v))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func barColor(_ v: Double) -> Color {
        if v > 0.7 { return .green }
        if v > 0.45 { return .blue }
        if v > 0.25 { return .orange }
        return .red
    }

    private var categoryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("内容识别").font(.headline)
            if record.categories.isEmpty {
                Text("未识别出明确类别")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                FlowChips(items: record.categories.map {
                    "\($0.zh) \(Int($0.confidence * 100))%"
                })
            }
            if record.faceCount > 0 {
                Label("检测到 \(record.faceCount) 张人脸", systemImage: "face.smiling")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var ocrBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("识别到的文字").font(.headline)
            Text(record.ocrText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("文件信息").font(.headline)
            row("尺寸", "\(record.pixelWidth) × \(record.pixelHeight)")
            row("像素", String(format: "%.1f MP", record.megapixels))
            if let s = record.fileSize {
                row("体积", ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
            }
            if let d = record.creationDate {
                row("拍摄时间", d.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.subheadline.monospacedDigit())
        }
    }
}

// MARK: - 流式标签布局

struct FlowChips: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chunked(), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { t in
                        Text(t)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 简单两列分组，避免引第三方流式布局
    private func chunked() -> [[String]] {
        var out: [[String]] = []
        var cur: [String] = []
        for i in items {
            cur.append(i)
            if cur.count == 2 { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
