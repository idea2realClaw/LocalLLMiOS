import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var state: AppState
    @State private var input = ""
    @State private var detail: Citation?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 状态条
            HStack(spacing: 8) {
                if state.isBusy && state.busyKind == .answering {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Text(state.status.isEmpty ? "全部推理在本机完成，不联网" : state.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !state.selectedBookIDs.isEmpty {
                    Text("限定 \(state.selectedBookIDs.count) 本")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.07))

            ScrollViewReader { proxy in
                ScrollView {
                    if state.messages.isEmpty {
                        emptyState
                            .padding(.top, 60)
                    }
                    LazyVStack(spacing: 18) {
                        ForEach(state.messages) { message in
                            MessageBubble(message: message) { index in
                                if let hit = state.citations.first(where: { $0.index == index }) {
                                    detail = hit
                                }
                            }
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: state.messages.last?.content ?? "") { _ in
                    if let last = state.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()
            inputBar
        }
        .navigationTitle("问这本书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    state.clearChat()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .disabled(state.isBusy)
            }
        }
        .sheet(item: $detail) { CitationDetailView(citation: $0) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 52))
                .foregroundStyle(.blue.opacity(0.55))
            Text("把书变成可以追问的 Wiki")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("1. 在「书库」导入 PDF / EPUB / TXT / MD")
                Text("2. bge 把全文切成知识块并编码成本地向量索引")
                Text("3. 提问时检索最相关的原文，交给 Qwen3.5-4B 作答")
                Text("4. 每个回答都带 [编号] 引用，可点开核对原文")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 420, alignment: .leading)
        }
        .padding()
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("就书里的内容提个问题…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(10)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .focused($isFocused)
                .onSubmit { if !input.isEmpty { send() } }

            if state.isBusy && state.busyKind == .answering {
                Button {
                    state.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(sendEnabled ? .blue : .gray)
                }
                .disabled(!sendEnabled)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var sendEnabled: Bool {
        !state.isBusy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = input
        input = ""
        isFocused = false
        state.ask(text)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let onCitation: (Int) -> Void

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 10) {
                Text(message.content.isEmpty && message.isStreaming ? "正在思考…" : message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if message.isStreaming {
                    ProgressView().controlSize(.small)
                }

                if !message.citations.isEmpty {
                    WrappingChips(citations: message.citations, onTap: onCitation)
                }
            }
            .padding(14)
            .background(
                message.role == .user ? Color.blue.opacity(0.14) : Color.gray.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .frame(maxWidth: 560, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer(minLength: 24) }
        }
    }
}

struct WrappingChips: View {
    let citations: [Citation]
    let onTap: (Int) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
            ForEach(citations) { c in
                Button {
                    onTap(c.index)
                } label: {
                    Text("[\(c.index)] \(c.chunk.bookTitle)")
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
