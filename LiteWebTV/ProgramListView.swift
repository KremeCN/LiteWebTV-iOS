import SwiftUI

/// 节目单侧边栏
/// Maps from Android: TvAdapters.kt (ProgramAdapter) + container_program in activity_main.xml
struct ProgramListView: View {
    let programs: [ProgramItem]
    let currentIndex: Int
    let safeAreaInsets: EdgeInsets

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            Text("节目单")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 16)

            // 节目单列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(programs.enumerated()), id: \.element.id) { offset, item in
                            ProgramRow(item: item)
                                .id(offset)
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
        .padding(.trailing, safeAreaInsets.trailing) // 显式注入右侧安全区避让
        .padding(.bottom, safeAreaInsets.bottom)     // 显式注入底部安全区避让
        .frame(width: 300 + safeAreaInsets.trailing)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
}

/// 单个节目行
private struct ProgramRow: View {
    let item: ProgramItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.time)
                .font(.system(size: 14))
                .foregroundColor(item.isCurrent ? Color(hex: "00FF00") : Color(hex: "AAAAAA"))

            Text(item.title)
                .font(.system(size: 16))
                .foregroundColor(item.isCurrent ? Color(hex: "00FF00") : .white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}
