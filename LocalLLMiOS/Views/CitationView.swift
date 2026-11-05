import SwiftUI
import Foundation

struct CitationView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if state.citations.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 46))
                        .foregroundStyle(.secondary)
                    Text("引用溯源")
                        .font(.title3.weight(.semibold))
                    Text("提出一个问题时，这里会列出被检索到的原文片段、所在章节与页码，用来核对答案。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.top, 60)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(state.citations) { citation in
                            CitationCard(citation: citation)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("引用溯源")
    }
}

struct CitationCard: View {
    @EnvironmentObject private var state: AppState
    let citation: Citation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("[\(citation.index)]")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.blue)
                Text("《\(citation.chunk.bookTitle)》")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.3f", citation.score))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(citation.chunk.location)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(citation.chunk.text)
                .font(.footnote)
                .textSelection(.enabled)
                .lineLimit(8)
            Button {
                state.loadChapters(of: citation.chunk.bookId)
                state.openChapter(citation.chunk.chapter)
            } label: {
                Label("在书库中查看该章节", systemImage: "arrow.right.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CitationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let citation: Citation

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("引用 [\(citation.index)]")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Text(String(format: "相似度 %.3f", citation.score))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("《\(citation.chunk.bookTitle)》 · \(citation.chunk.location)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text(citation.chunk.text)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding()
            }
            .navigationTitle("原文片段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
