import SwiftUI

/// 频道列表侧边栏
struct ChannelListView: View {
    let channels: [LogicalChannel]
    let currentIndex: Int
    let realSafeAreaLeft: CGFloat
    let onSelect: (Int) -> Void
    let onSelectSource: (Int, StreamSource) -> Void

    @State private var sourceMenuIndex: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let sourceMenuIndex, channels.indices.contains(sourceMenuIndex) {
                pageContainer {
                    sourceHeader
                    sourceMenu(for: channels[sourceMenuIndex], at: sourceMenuIndex)
                }
                .transition(.move(edge: .trailing))
            } else {
                pageContainer {
                    Text("频道列表")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.bottom, 16)
                    channelList
                }
                .transition(.move(edge: .leading))
            }
        }
        .clipped()
        .frame(width: 300 + realSafeAreaLeft)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }

    private func pageContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(16)
        .padding(.leading, realSafeAreaLeft)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sourceHeader: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    sourceMenuIndex = nil
                }
            } label: {
                SidebarChevron(pointsLeft: true)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 11, height: 18)
                    .frame(width: 44, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("播放源")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                if let sourceMenuIndex, channels.indices.contains(sourceMenuIndex) {
                    Text(channels[sourceMenuIndex].name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(hex: "BBBBBB"))
                }
            }
        }
        .padding(.bottom, 16)
    }

    private var channelList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { offset, item in
                        if !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ChannelRow(
                                item: item,
                                onSelectChannel: {
                                    onSelect(offset)
                                },
                                onOpenSourceMenu: {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        sourceMenuIndex = offset
                                    }
                                }
                            )
                            .id(offset)
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

    private func sourceMenu(for channel: LogicalChannel, at index: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(channel.availableSources, id: \.self) { source in
                    SourceRow(
                        source: source,
                        isSelected: channel.selectedSource == source
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectSource(index, source)
                    }
                }
            }
        }
    }
}

private struct ChannelRow: View {
    let item: LogicalChannel
    let onSelectChannel: () -> Void
    let onOpenSourceMenu: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(item.name)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(item.isActive ? Color(hex: "00FF00") : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelectChannel)

            if item.canSwitchSource {
                HStack(spacing: 6) {
                    Text(item.selectedSource.displayName)
                        .font(.system(size: 11, weight: .medium))
                    SidebarChevron(pointsLeft: false)
                        .stroke(Color(hex: "00A1D6"), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 7, height: 11)
                }
                .foregroundColor(Color(hex: "00A1D6"))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.12))
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenSourceMenu)
            }
        }
        .padding(.vertical, 12)
        .padding(.leading, 12)
        .padding(.trailing, item.canSwitchSource ? 4 : 12)
        .background(Color.white.opacity(0.001))
    }
}

private struct SourceRow: View {
    let source: StreamSource
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(source.displayName)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(isSelected ? Color(hex: "00FF00") : .white)

            Spacer()

            if isSelected {
                SidebarCheckmark()
                    .stroke(Color(hex: "00FF00"), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.001))
    }
}

private struct SidebarChevron: Shape {
    var pointsLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsLeft {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        return path
    }
}

private struct SidebarCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
