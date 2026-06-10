import LinkoKit
import SwiftUI

/// Settings scene: ports, sing-box binary path override, delay test URL.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var mixedPortText = ""
    @State private var clashAPIPortText = ""
    @State private var binaryPathText = ""
    @State private var delayTestURLText = ""
    @State private var feedback: String?
    @State private var feedbackIsError = false

    var body: some View {
        Form {
            TextField("混合代理端口", text: $mixedPortText)
            TextField("Clash API 端口", text: $clashAPIPortText)
            TextField("sing-box 路径（留空自动查找）", text: $binaryPathText)
            TextField("延迟测试地址", text: $delayTestURLText)
            if !appState.isBinaryAvailable {
                Text("未找到 sing-box：请填写上方路径，或运行 scripts/fetch-singbox.sh，或执行 brew install sing-box。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(feedbackIsError ? Color.red : Color.secondary)
                }
                Spacer()
                Button("保存并应用", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: loadFields)
    }

    private func loadFields() {
        let preferences = appState.preferences
        mixedPortText = String(preferences.mixedPort)
        clashAPIPortText = String(preferences.clashAPIPort)
        binaryPathText = preferences.singBoxBinaryPathOverride ?? ""
        delayTestURLText = preferences.delayTestURL
    }

    private func save() {
        guard
            let mixedPort = Int(mixedPortText.trimmingCharacters(in: .whitespaces)),
            let clashAPIPort = Int(clashAPIPortText.trimmingCharacters(in: .whitespaces)),
            (1...65535).contains(mixedPort),
            (1...65535).contains(clashAPIPort),
            mixedPort != clashAPIPort
        else {
            feedback = "端口无效：请输入 1–65535 之间的数字，且两个端口不能相同。"
            feedbackIsError = true
            return
        }

        var preferences = appState.preferences
        preferences.mixedPort = mixedPort
        preferences.clashAPIPort = clashAPIPort
        let trimmedPath = binaryPathText.trimmingCharacters(in: .whitespaces)
        preferences.singBoxBinaryPathOverride = trimmedPath.isEmpty ? nil : trimmedPath
        let trimmedURL = delayTestURLText.trimmingCharacters(in: .whitespaces)
        preferences.delayTestURL = trimmedURL.isEmpty ? AppPreferences.default.delayTestURL : trimmedURL

        feedback = appState.isSystemProxyEnabled ? "已保存，正在重启核心…" : "已保存。"
        feedbackIsError = false
        Task {
            await appState.updatePreferences(preferences)
        }
    }
}
