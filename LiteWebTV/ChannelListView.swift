import SwiftUI

/// 频道列表侧边栏
/// Maps from Android: TvAdapters.kt (ChannelAdapter) + container_channel in activity_main.xml
struct ChannelListView: View {
    let channels: [ChannelItem]
    let currentIndex: Int
    let onSelect: (ChannelItem) -> Void

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                // 标题
                Text("频道列表")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.bottom, 16)

                // 频道列表
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(channels.enumerated()), id: \.element.id) { offset, item in
                                ChannelRow(item: item)
                                    .id(offset)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onSelect(item)
                                    }
                            }
                        }
                    }
                    .onAppear {
                        // 自动滚动到当前频道
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation {
                                proxy.scrollTo(currentIndex, anchor: .center)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .padding(.leading, geo.safeAreaInsets.leading) // 避让刘海/灵动岛
            .frame(width: 300 + geo.safeAreaInsets.leading)
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.9)) // #E6000000
        }
        .frame(width: 300 + (UIApplication.shared.windows.first?.safeAreaInsets.left ?? 0))
    }
}

/// 单个频道行
private struct ChannelRow: View {
    let item: ChannelItem

    var body: some View {
        Text(item.name)
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(item.isActive ? Color(hex: "00FF00") : .white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.001)) // 确保整行可点击
    }
}
