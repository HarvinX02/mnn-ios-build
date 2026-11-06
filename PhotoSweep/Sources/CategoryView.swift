import SwiftUI
import Photos

// MARK: - 分类页

/// 独立的分类浏览窗口：
///   上半部分是「题材」（截图/人像/风景…，由 KindClassifier 判定）
///   下半部分是「内容」（猫/食物/文档…，来自 Vision 标签）
/// 点进去就是该类的图库网格，可以直接批选删除。
struct CategoryView: View {
    @EnvironmentObject var scanner: LibraryScanner

    @State private var mode: Mode = .kind
    @State private var selection = Set<String>()
    @State private var selecting = false
    @State private var showDeleteConfirm = false
    @State private var pendingDelete: [String] = []

    enum Mode: String, CaseIterable, Identifiable {
        case kind = "题材"
        case content = "内容"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if scanner.records.isEmpty {
                    ContentUnavailableView(
                        "还没有分析结果",
                        systemImage: "square.grid.2x2",
                        description: Text("先到「扫描」页跑一次相册分析")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            Picker("分组方式", selection: $mode) {
                                ForEach(Mode.allCases) { m in
                                    Text(m.rawValue).tag(m)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)

                            if mode == .kind {
                                kindGrid
                            } else {
                                contentGrid
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("分类")
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完成") {
                            selecting = false
                            selection.removeAll()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            pendingDelete = Array(selection)
                            showDeleteConfirm = true
                        } label: {
                            Label("删除 \(selection.count) 张", systemImage: "trash")
                        }
                        .disabled(selection.isEmpty)
                    }
                }
            }
            .confirmationDialog(
                "确认删除 \(pendingDelete.count) 张照片？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    let ids = pendingDelete
                    pendingDelete = []
                    selection.removeAll()
                    selecting = false
                    Task { try? await scanner.delete(ids: ids) }
                }
                Button("取消", role: .cancel) { pendingDelete = [] }
            } message: {
                Text("会从系统相册移除，进入「最近删除」，30 天内可恢复。")
            }
        }
    }

    // MARK: 题材分组

    private struct KindBucket: Identifiable {
        let kind: PhotoKind
        let records: [PhotoRecord]
        var id: String { kind.rawValue }
        var avgScore: Double {
            guard !records.isEmpty else { return 0 }
            return records.reduce(0) { $0 + $1.qualityScore } / Double(records.count)
        }
        var flawed: Int { records.filter { !$0.issues.isEmpty }.count }
    }

    private var kindBuckets: [KindBucket] {
        var map: [PhotoKind: [PhotoRecord]] = [:]
        for r in scanner.records { map[r.kind, default: []].append(r) }
        return map
            .map { KindBucket(kind: $0.key, records: $0.value) }
            .sorted { $0.records.count > $1.records.count }
    }

    private var kindGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            ForEach(kindBuckets) { b in
                NavigationLink {
                    BucketDetail(
                        title: b.kind.rawValue,
                        subtitle: "按「\(b.kind.rawValue)」标准评分",
                        symbol: b.kind.symbol,
                        records: b.records
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: b.kind.symbol)
                                .font(.title3)
                                .foregroundStyle(.tint)
                            Spacer()
                            Text("\(b.records.count)")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                        }
                        Text(b.kind.rawValue)
                            .font(.headline)
                        HStack(spacing: 8) {
                            Text(String(format: "均分 %.0f", b.avgScore * 100))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if b.flawed > 0 {
                                Text("\(b.flawed) 张有缺陷")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    // MARK: 内容分组

    private struct ContentBucket: Identifiable {
        let name: String
        let records: [PhotoRecord]
        var id: String { name }
    }

    private var contentBuckets: [ContentBucket] {
        var map: [String: [PhotoRecord]] = [:]
        for r in scanner.records {
            let key = r.primaryCategory.isEmpty ? "其他" : r.primaryCategory
            map[key, default: []].append(r)
        }
        return map
            .map { ContentBucket(name: $0.key, records: $0.value) }
            .sorted { $0.records.count > $1.records.count }
    }

    private var contentGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
            ForEach(contentBuckets) { b in
                NavigationLink {
                    BucketDetail(
                        title: b.name,
                        subtitle: "按内容识别归类",
                        symbol: "tag",
                        records: b.records
                    )
                } label: {
                    VStack(spacing: 6) {
                        Text(b.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text("\(b.records.count) 张")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - 某个分类下的照片列表

struct BucketDetail: View {
    let title: String
    let subtitle: String
    let symbol: String
    let records: [PhotoRecord]

    @EnvironmentObject var scanner: LibraryScanner
    @State private var sortWorstFirst = true
    @State private var selection = Set<String>()
    @State private var selecting = false
    @State private var showDeleteConfirm = false
    @State private var pendingDelete: [String] = []

    private var sorted: [PhotoRecord] {
        sortWorstFirst
            ? records.sorted { $0.qualityScore < $1.qualityScore }
            : records.sorted { $0.qualityScore > $1.qualityScore }
    }

    private let cols = [GridItem(.adaptive(minimum: 108), spacing: 4)]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Label("\(records.count) 张", systemImage: symbol)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("排序", selection: $sortWorstFirst) {
                        Text("最差优先").tag(true)
                        Text("最好优先").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                .padding(.horizontal)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                LazyVGrid(columns: cols, spacing: 4) {
                    ForEach(sorted) { rec in
                        ZStack(alignment: .topTrailing) {
                            NavigationLink {
                                DetailView(record: rec)
                            } label: {
                                ThumbView(id: rec.id)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(alignment: .bottomLeading) {
                                        Text(String(format: "%.0f", rec.qualityScore * 100))
                                            .font(.caption2.weight(.bold).monospacedDigit())
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(.ultraThinMaterial, in: Capsule())
                                            .padding(4)
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        if let first = rec.issues.first {
                                            Image(systemName: first.symbol)
                                                .font(.caption2)
                                                .padding(4)
                                                .background(.ultraThinMaterial, in: Circle())
                                                .padding(4)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(selecting)

                            if selecting {
                                Button {
                                    if selection.contains(rec.id) {
                                        selection.remove(rec.id)
                                    } else {
                                        selection.insert(rec.id)
                                    }
                                } label: {
                                    Image(systemName: selection.contains(rec.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selection.contains(rec.id) ? .blue : .white)
                                        .background(Circle().fill(.black.opacity(0.25)))
                                        .padding(5)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selecting {
                    Button("完成") {
                        selecting = false
                        selection.removeAll()
                    }
                } else {
                    Button("选择") { selecting = true }
                }
            }
            if selecting {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        pendingDelete = Array(selection)
                        showDeleteConfirm = true
                    } label: {
                        Label("删除 \(selection.count) 张", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        .confirmationDialog(
            "确认删除 \(pendingDelete.count) 张照片？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                let ids = pendingDelete
                pendingDelete = []
                selection.removeAll()
                selecting = false
                Task { try? await scanner.delete(ids: ids) }
            }
            Button("取消", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("会从系统相册移除，进入「最近删除」，30 天内可恢复。")
        }
    }
}
