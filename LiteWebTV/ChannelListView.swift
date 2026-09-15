import SwiftUI

/// 频道列表侧边栏
struct ChannelListView: View {
    let channels: [LogicalChannel]
    let currentIndex: Int
    let realSafeAreaLeft: CGFloat
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("频道列表")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 16)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(channels.enumerated()), id: \.element.id) { offset, item in
                            if let group = item.group, shouldShowGroupHeader(at: offset) {
                                Text(group)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(hex: "00A1D6"))
                                    .padding(.top, offset == 0 ? 0 : 12)
                                    .padding(.bottom, 8)
                            }

                            ChannelRow(item: item)
                                .id(offset)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(offset)
                                }
                        }
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation {
                            proxy.scrollTo(currentIndex, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(16)
        .padding(.leading, realSafeAreaLeft)
        .frame(width: 300 + realSafeAreaLeft)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }

    private func shouldShowGroupHeader(at offset: Int) -> Bool {
        guard let group = channels[offset].group else { return false }
        if offset == 0 { return true }
        return channels[offset - 1].group != group
    }
}

private struct ChannelRow: View {
    let item: LogicalChannel

    var body: some View {
        HStack(spacing: 8) {
            Text(item.name)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(item.isActive ? Color(hex: "00FF00") : .white)

            if item.canSwitchSource {
                Text(item.selectedSource.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "BBBBBB"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.12))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.001))
    }
}
