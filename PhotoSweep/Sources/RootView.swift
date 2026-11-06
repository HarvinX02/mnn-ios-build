import SwiftUI
import Photos

struct RootView: View {
    @StateObject private var scanner = LibraryScanner()
    @State private var showPermission = false

    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("扫描", systemImage: "sparkle.magnifyingglass") }

            GalleryView()
                .tabItem { Label("图库", systemImage: "square.grid.2x2") }

            SimilarView()
                .tabItem { Label("相似", systemImage: "rectangle.stack") }
        }
        .environmentObject(scanner)
        .task {
            scanner.loadCache()
            let ok = await scanner.requestPermission()
            if !ok { showPermission = true }
        }
        .alert("需要相册权限", isPresented: $showPermission) {
            Button("去设置") {
                if let u = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(u)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请允许访问照片，才能分析清晰度与内容分类。所有处理都在本机完成。")
        }
    }
}

// MARK: - 扫描页

struct ScanView: View {
    @EnvironmentObject var scanner: LibraryScanner
    @State private var enableOCR = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerCard
                    actionCard
                    statsCard
                    if !scanner.groups.isEmpty { similarHint }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("照片清扫")
        }
    }

    private var headerCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("本机批量分析")
                .font(.headline)
            Text("清晰度 · 曝光 · 内容分类 · 文字识别\n全部离线完成，不联网、不上传")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var actionCard: some View {
        VStack(spacing: 14) {
            Toggle("识别照片中的文字（较慢）", isOn: $enableOCR)
                .onChange(of: enableOCR) { _, v in scanner.enableOCR = v }

            switch scanner.phase {
            case .idle, .finished, .failed:
                Button {
                    scanner.enableOCR = enableOCR
                    scanner.startScan()
                } label: {
                    Label(scanner.records.isEmpty ? "开始扫描相册" : "继续扫描新照片",
                          systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .enumerating:
                ProgressView("正在读取相册…")
                    .frame(maxWidth: .infinity)

            case .analyzing(let done, let total):
                VStack(spacing: 8) {
                    ProgressView(value: Double(done), total: Double(max(1, total))) {
                        Text("分析中 \(done) / \(total)")
                            .font(.subheadline)
                    }
                    Text(etaText(done: done, total: total))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("停止", role: .destructive) { scanner.cancel() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func etaText(done: Int, total: Int) -> String {
        let remain = total - done
        // 实测约 4 张/秒（4 线程）
        let sec = Double(remain) / 4.0
        if sec < 60 { return "预计还需 \(Int(sec)) 秒" }
        return "预计还需 \(Int(sec / 60)) 分钟"
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("统计")
                .font(.headline)

            HStack(spacing: 12) {
                StatTile(title: "已分析", value: "\(scanner.records.count)", unit: "张")
                StatTile(title: "相似组",
                         value: "\(scanner.groups.count)",
                         unit: "组")
                StatTile(title: "有缺陷",
                         value: "\(scanner.records.filter { !$0.issues.isEmpty }.count)",
                         unit: "张")
            }

            if !scanner.records.isEmpty {
                Divider()
                Text("各类题材分布")
                    .font(.subheadline.weight(.medium))
                kindBar
                Divider()
                Text("本类质量分布")
                    .font(.subheadline.weight(.medium))
                gradeBar
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// 题材分布：让你直接看到相册构成，而不是一个笼统的总分
    private var kindBar: some View {
        let total = max(1, scanner.records.count)
        var counter: [PhotoKind: Int] = [:]
        for r in scanner.records { counter[r.kind, default: 0] += 1 }
        let rows = counter.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(rows, id: \.key) { kind, n in
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: kind.symbol).font(.caption2)
                        Text(kind.rawValue).font(.caption)
                    }
                    .frame(width: 66, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule()
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(width: geo.size.width * CGFloat(n) / CGFloat(total))
                        }
                    }
                    .frame(height: 8)
                    Text("\(n)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
    }

    private var gradeBar: some View {
        let total = max(1, scanner.records.count)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(QualityGrade.allCases) { g in
                let n = scanner.records.filter { $0.grade == g }.count
                HStack(spacing: 8) {
                    Text(g.rawValue)
                        .font(.caption)
                        .frame(width: 34, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule()
                                .fill(color(for: g))
                                .frame(width: geo.size.width * CGFloat(n) / CGFloat(total))
                        }
                    }
                    .frame(height: 8)
                    Text("\(n)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private func color(for g: QualityGrade) -> Color {
        switch g {
        case .excellent: return .green
        case .good: return .blue
        case .fair: return .orange
        case .poor: return .red
        }
    }

    private var similarHint: some View {
        NavigationLink {
            SimilarView()
        } label: {
            HStack {
                Image(systemName: "rectangle.stack.badge.minus")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现 \(scanner.groups.count) 组相似照片")
                        .font(.subheadline.weight(.medium))
                    Text("可批量保留最佳、删除其余")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 统计小卡片

struct StatTile: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
