import SwiftUI

/// 管理员验证：输入 App 内置的管理员账号密码，通过后才能进导出流程。
/// 改用 App 自己的账号体系（AccountStore），不再调用系统面容 / 锁屏
/// 密码——之前用 LAContext 的 .deviceOwnerAuthentication 会先弹
/// “为壁纸匣输入 iPhone 密码”，用户以为要输手机锁屏密码；现在
/// 只认 AccountView 里预置的那一个管理员账号。
struct AdminLoginView: View {
    var onUnlock: () -> Void
    @StateObject private var store = AccountStore()
    @State private var username = AccountStore.ownerUsername
    @State private var password = ""
    @State private var error: String?
    @State private var token = ""
    @State private var tokenSaved = false
    @State private var tokenNote = ""

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("管理员登录")
                .font(.title2.weight(.semibold))
            Text("导出已安装的壁纸前，请输入管理员账号密码。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 12) {
                TextField("账号", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(login)
            }
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                login()
            } label: {
                Label("管理员登录", systemImage: "person.badge.key")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(username.isEmpty || password.isEmpty)
            Text("只认提前写好的管理员账号，没有注册入口。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Divider()
            // GitHub 钥匙：跟“我的账号”页是同一把（同一钥匙串），这边也能贴、也能存，
            // 导出要推目录时直接用，不用再回账号页填。标题和说明不写，只留输入框。
            VStack(alignment: .leading, spacing: 8) {
                SecureField("贴入钥匙", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                HStack {
                    Button("保存钥匙") {
                        store.saveToken(token)
                        token = ""
                        tokenSaved = true
                        tokenNote = "钥匙已保存。"
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(token.isEmpty)
                    if tokenSaved {
                        Button("清除钥匙", role: .destructive) {
                            store.clearToken()
                            tokenSaved = false
                            tokenNote = "钥匙已清除。"
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if !tokenNote.isEmpty { Text(tokenNote).font(.caption).foregroundStyle(.secondary) }
                Text(tokenSaved ? "钥匙状态：已保存" : "钥匙状态：未保存")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .onAppear { tokenSaved = store.hasToken }
    }

    private func login() {
        if let message = store.login(username: username, password: password) {
            error = message
        } else {
            error = nil
            onUnlock()
        }
    }
}
