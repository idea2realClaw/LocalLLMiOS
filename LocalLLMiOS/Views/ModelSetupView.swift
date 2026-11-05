import SwiftUI
import UniformTypeIdentifiers

struct ModelSetupView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var models = ModelManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showFileImporter = false
    @State private var importTarget = AppPaths.qwenFileName
    @State private var lanBaseURL = "http://192.168.1.10:8899/"
    @State private var busyFile: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(models.statuses) { status in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: status.complete
                                      ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(status.complete ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(status.requirement.displayName)
                                        .font(.subheadline.weight(.medium))
                                    Text(status.requirement.purpose)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(status.exists ? status.sizeText : "未安装")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !status.complete && status.exists {
                                Text("文件不完整，请重新导入或继续下载")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if let p = models.downloading[status.requirement.fileName] {
                                ProgressView(value: p) {
                                    Text("下载中 \(Int(p * 100))%").font(.caption2)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("模型状态")
                } footer: {
                    Text("两个 GGUF 都放在 App 的 Documents/Models 目录，全部推理离线进行。")
                }

                Section("方式一 · 从「文件」App 导入") {
                    ForEach(ModelRequirement.all) { req in
                        Button {
                            importTarget = req.fileName
                            showFileImporter = true
                        } label: {
                            Label("选择 \(req.displayName).gguf", systemImage: "folder.badge.plus")
                                .font(.subheadline)
                        }
                    }
                    Text("也可用 Finder 的文件共享把 GGUF 拖进本 App 的 Documents 目录。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("例如 http://192.168.1.10:8899/", text: $lanBaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    ForEach(ModelRequirement.all) { req in
                        Button {
                            startDownload(req: req, base: URL(string: lanBaseURL))
                        } label: {
                            Label("下载 \(req.fileName)", systemImage: "arrow.down.circle")
                                .font(.caption)
                        }
                        .disabled(busyFile != nil)
                    }
                    if busyFile != nil {
                        Button(role: .cancel) {
                            models.cancelDownload()
                            busyFile = nil
                        } label: {
                            Text("暂停下载（保留 .part，可续传）")
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("方式二 · 局域网 / 公网 URL 下载")
                } footer: {
                    Text("在 Mac 上执行 python3 scripts/serve_models.py，把打印出的地址填到这里；手机与 Mac 需同一 Wi-Fi。支持 Range 断点续传。")
                }

                Section("维护") {
                    ForEach(ModelRequirement.all) { req in
                        Button(role: .destructive) {
                            models.deleteModel(req.fileName)
                        } label: {
                            Text("删除 \(req.fileName)")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("本地模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { models.refresh() }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        try models.importFile(from: url, as: importTarget)
                        state.notice = "模型已导入"
                    } catch {
                        state.errorMessage = error.localizedDescription
                    }
                case .failure(let error):
                    state.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startDownload(req: ModelRequirement, base: URL?) {
        guard let base else {
            state.errorMessage = "地址不合法"
            return
        }
        let target = base.appendingPathComponent(req.fileName)
        busyFile = req.fileName
        models.download(from: target, as: req.fileName, progress: { _ in }) { result in
            busyFile = nil
            if case .failure(let error) = result {
                state.errorMessage = "下载失败：\(error.localizedDescription)。可改用公网直链或文件导入。"
            }
        }
    }
}
