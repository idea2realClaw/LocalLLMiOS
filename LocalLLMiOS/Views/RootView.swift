import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var tab = 1

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    LibraryView()
                } content: {
                    ChatView()
                } detail: {
                    CitationView()
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                TabView(selection: $tab) {
                    NavigationStack { LibraryView() }
                        .tabItem { Label("书库", systemImage: "books.vertical") }
                        .tag(0)
                    NavigationStack { ChatView() }
                        .tabItem { Label("问答", systemImage: "bubble.left.and.bubble.right") }
                        .tag(1)
                    NavigationStack { CitationView() }
                        .tabItem { Label("引用", systemImage: "doc.text.magnifyingglass") }
                        .tag(2)
                }
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .alert("提示", isPresented: Binding(
            get: { state.notice != nil },
            set: { if !$0 { state.notice = nil } }
        )) {
            Button("好", role: .cancel) { state.notice = nil }
        } message: {
            Text(state.notice ?? "")
        }
    }
}
