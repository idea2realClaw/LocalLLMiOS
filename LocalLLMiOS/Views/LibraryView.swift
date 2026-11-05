import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var state: AppState
    @State private var showImporter = false
    @State private var showModels = false
    @State private var showSettings = false

    private var allowedTypes: [UTType] {
        [.pdf, .plainText,
         UTType(filenameExtension: "epub") ?? .data,
         UTType(filenameExtension: "md") ?? .data,
         .data]
    }

    var body: some View {
        List {
            if !state.models.allReady {
                Section {
                    Button {
                        showModels = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("模型尚未就绪")
                                    .font(.headline)
                                Text("导入 Qwen3.5-4B 与 bge GGUF 后才能问答")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("导入书籍（PDF / EPUB / TXT / MD）", systemImage: "plus.circle.fill")
                }
                .disabled(state.isBusy)

                if state.isBusy && state.busyKind == .importing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.status).font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: state.progress)
                        Text("\(Int(state.progress * 100))% · 首次编码一本书通常需要几分钟")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("书库")
            } footer: {
                Text("勾选书籍可把检索范围限定在选中书内；不勾选则检索全部。")
            }

            Section("已导入（\(state.books.count)）") {
                if state.books.isEmpty {
                    Text("还没有书。点上方按钮导入一本试试。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(state.books) { book in
                    HStack(spacing: 12) {
                        Image(systemName: state.selectedBookIDs.contains(book.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(state.selectedBookIDs.contains(book.id) ? .blue : .secondary)
                            .onTapGesture { state.toggleScope(book) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(book.displayTitle)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(book.format.rawValue)
                                Text("·")
                                Text("\(book.chunkCount) 块")
                                Text("·")
                                Text(book.isIndexed ? "已索引" : "处理中")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            state.loadChapters(of: book.id)
                        } label: {
                            Image(systemName: "list.bullet.indent")
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { state.deleteBook(book) } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }

            if let book = state.books.first(where: { $0.id == state.activeBookID }),
               !state.chapters.isEmpty {
                Section("《\(book.displayTitle)》章节") {
                    ForEach(Array(state.chapters.indices), id: \.self) { index in
                        let chapter = state.chapters[index]
                        NavigationLink {
                            ChapterReaderView(title: chapter.title)
                        } label: {
                            HStack {
                                Text(chapter.title).lineLimit(1)
                                Spacer()
                                Text("\(chapter.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            state.openChapter(chapter.title)
                        })
                    }
                }
            }
        }
        .navigationTitle("本地 AI Wiki")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showModels = true
                } label: {
                    Label("模型", systemImage: state.models.allReady
                          ? "checkmark.shield" : "exclamationmark.shield")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .onAppear { state.reloadBooks() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: allowedTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { state.importBook(url: url) }
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showModels) { ModelSetupView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

struct ChapterReaderView: View {
    @EnvironmentObject private var state: AppState
    let title: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(state.chapterChunks) { chunk in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(chunk.location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(chunk.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .onAppear { state.openChapter(title) }
    }
}
