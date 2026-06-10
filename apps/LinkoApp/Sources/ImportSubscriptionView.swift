import SwiftUI

/// Small window for importing a Clash YAML subscription by URL.
struct ImportSubscriptionView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入订阅")
                .font(.headline)
            TextField("订阅地址（Clash YAML 链接）", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .onSubmit(startImport)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 380, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(isImporting ? "导入中…" : "导入", action: startImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isImporting || trimmedURLString.isEmpty)
            }
        }
        .padding(20)
    }

    private var trimmedURLString: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startImport() {
        guard !isImporting, !trimmedURLString.isEmpty else { return }
        errorMessage = nil
        isImporting = true
        Task {
            do {
                let warnings = try await appState.importSubscription(urlString: trimmedURLString)
                if !warnings.isEmpty {
                    appState.lastErrorMessage = "导入完成，已跳过 \(warnings.count) 个无法识别的节点。"
                }
                isImporting = false
                dismiss()
            } catch {
                isImporting = false
                errorMessage = (error as? AppError)?.message ?? error.localizedDescription
            }
        }
    }
}
