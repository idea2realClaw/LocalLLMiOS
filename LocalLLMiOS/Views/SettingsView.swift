import SwiftUI
import Foundation

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var totalChunks = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("检索") {
                    Stepper("返回片段 Top-K：\(settings.topK)", value: $settings.topK, in: 1...12)
                    Slider(value: $settings.minScore, in: 0...0.6, step: 0.05) {
                        Text("相似度下限")
                    } minimumValueLabel: {
                        Text("0").font(.caption2)
                    } maximumValueLabel: {
                        Text("0.6").font(.caption2)
                    }
                    Text(String(format: "当前 %.2f；过低会引入无关片段，过高可能召回不足", settings.minScore))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("问题加 bge 检索指令前缀", isOn: $settings.queryInstructionEnabled)
                    Text("bge-small-zh-v1.5 用短问题检索长段落时，加中文指令通常更稳。修改后仅影响新提问。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("分块（修改后仅对新导入的书生效）") {
                    Stepper("块大小：\(settings.chunkSize) 字", value: $settings.chunkSize, in: 120...420, step: 20)
                    Stepper("重叠：\(settings.chunkOverlap) 字", value: $settings.chunkOverlap, in: 0...120, step: 10)
                    Text("bge 上下文上限 512 token，中文约 1 字 1 token，块不宜超过 420 字。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("生成") {
                    Stepper("最大输出：\(settings.maxTokens) token", value: $settings.maxTokens, in: 128...1024, step: 64)
                    Slider(value: $settings.temperature, in: 0.1...1.2, step: 0.05) {
                        Text("温度")
                    } minimumValueLabel: {
                        Text("0.1").font(.caption2)
                    } maximumValueLabel: {
                        Text("1.2").font(.caption2)
                    }
                    Text(String(format: "当前 %.2f；问答建议 0.5–0.8", settings.temperature))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("上下文长度", selection: $settings.contextSize) {
                        ForEach([2048, 3072, 4096, 6144, 8192], id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    Text("越大越占内存；iPhone 上 4096 是较稳的起点，改动后模型会重新加载。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("Metal 卸载层数", selection: $settings.gpuLayers) {
                        Text("全部（-1）").tag(-1)
                        Text("仅 CPU（0）").tag(0)
                        Text("前 20 层").tag(20)
                        Text("99 层").tag(99)
                    }
                }

                Section("维护") {
                    Button {
                        state.releaseEngines()
                    } label: {
                        Label("释放模型内存", systemImage: "memorychip")
                    }
                    Button(role: .destructive) {
                        state.clearChat()
                    } label: {
                        Label("清空当前对话", systemImage: "trash")
                    }
                }

                Section("关于") {
                    LabeledContent("llama.cpp", value: LlamaBackend.version)
                    LabeledContent("生成模型", value: "Qwen3.5-4B Q4_K_M")
                    LabeledContent("嵌入模型", value: "bge-small-zh-v1.5 (512 维 / CLS)")
                    LabeledContent("本地知识块", value: "\(totalChunks)")
                    LabeledContent("数据", value: "100% 端上，无网络请求")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                totalChunks = (try? state.pipeline.totalChunks()) ?? 0
            }
        }
    }
}
