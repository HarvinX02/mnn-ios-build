import SwiftUI

// MARK: - 相似组页

struct SimilarView: View {
    @EnvironmentObject var scanner: LibraryScanner
    @State private var pendingDelete: SimilarGroup?
    @State private var showConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if scanner.groups.isEmpty {
                    ContentUnavailableView("没有相似照片",
                                           systemImage: "rectangle.stack",
                                           description: Text("扫描完成后，连拍和重复照片会自动归组"))
                } else {
                    List {
                        Section {
                            summaryRow
                        }
                        ForEach(scanner.groups) { g in
                            Section {
                                groupContent(g)
                            } header: {
                                HStack {
                                    Text("\(g.count) 张相似")
                                    Spacer()
                                    Text(ByteCountFormatter.string(
                                        fromByteCount: g.savings, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("相似照片")
            .confirmationDialog(confirmTitle,
                                isPresented: $showConfirm,
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    guard let g = pendingDelete else { return }
                    let ids = g.records.filter { $0.id != g.keeperID }.map { $0.id }
                    pendingDelete = nil
                    Task { try? await scanner.delete(ids: ids) }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("每组保留画质最高的一张，其余从相册删除。此操作不可撤销。")
            }
        }
    }

    private var confirmTitle: String {
        guard let g = pendingDelete else { return "确认删除？" }
        return "删除该组中除最佳外的 \(g.count - 1) 张？"
    }

    private var summaryRow: some View {
        let totalExtra = scanner.groups.reduce(0) { $0 + ($1.count - 1) }
        let totalBytes = scanner.groups.reduce(Int64(0)) { $0 + $1.savings }
        return VStack(alignment: .leading, spacing: 6) {
            Text("共 \(scanner.groups.count) 组，可清理 \(totalExtra) 张")
                .font(.headline)
            Text("原始体积合计约 \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func groupContent(_ g: SimilarGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(g.records) { rec in
                        VStack(spacing: 3) {
                            ZStack(alignment: .topLeading) {
                                ThumbView(id: rec.id, size: 160)
                                    .frame(width: 86, height: 86)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay {
                                        if rec.id == g.keeperID {
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(Color.green, lineWidth: 2.5)
                                        }
                                    }
                                if rec.id == g.keeperID {
                                    Text("留")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.green, in: Capsule())
                                        .padding(3)
                                }
                            }
                            Text(rec.isScored ? String(format: "%.0f", rec.qualityScore * 100) : "N/A")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Button(role: .destructive) {
                pendingDelete = g
                showConfirm = true
            } label: {
                Label("保留最佳，删除其余 \(g.count - 1) 张", systemImage: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }
}
