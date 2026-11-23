import SwiftUI

/// 效果器图鉴：真机界面截图 + 名称对照。
/// 三端展示同一份 `fxlib.json`，所以这里不写死任何算法名单。
struct FxGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var zoom: ZoomTarget?

    private let groups = FxGallery.shared.groups
    private let cols = [GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)]

    private struct ZoomTarget: Identifiable {
        let id = UUID()
        let item: FxGallery.Item
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if groups.count > 1 {
                    Picker("", selection: $tab) {
                        ForEach(groups.indices, id: \.self) { i in
                            Text(groups[i].title).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                if groups.isEmpty {
                    Spacer()
                    Text("图鉴数据未随包携带")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        Text(groups[min(tab, groups.count - 1)].label)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.bottom, 6)

                        LazyVGrid(columns: cols, spacing: 12) {
                            ForEach(groups[min(tab, groups.count - 1)].items) { item in
                                cell(item)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("效果器图鉴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $zoom) { t in
                ZoomView(item: t.item)
            }
        }
    }

    private func cell(_ item: FxGallery.Item) -> some View {
        Button {
            zoom = ZoomTarget(item: item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                // 面板图是 480×134 这种宽条形，等宽铺满、按比例缩高
                if let img = FxGallery.shared.image(item.img) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.systemGray5))
                        .frame(height: 56)
                        .overlay(Text("无图").font(.caption2).foregroundColor(.secondary))
                }
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(.caption).bold()
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let tag = item.tag {
                        Text(tag)
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color(.systemGray6))
                            .cornerRadius(4)
                            .foregroundColor(item.isHeavy ? .orange : .secondary)
                            .lineLimit(1)
                    }
                }
                if let sub = item.subtitle {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 单张放大（抖动图看不清旋钮时刻度时用）
private struct ZoomView: View {
    let item: FxGallery.Item
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                if let img = FxGallery.shared.image(item.img) {
                    // 放大 2 倍：原图 480×134，2 倍后旋钮刻度可辨
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: UIScreen.main.bounds.width * 2)
                }
            }
            .background(Color.black)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
