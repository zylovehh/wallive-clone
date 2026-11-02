// AccountView.swift
// 管理员登入页：账号密码提前写在 App 里，只有这一个账号能登入，没有注册入口。
// 别人不用登入、直接进目录；登入入口只在目录页右上角人头按钮里。
// 密码不写原文，只写加密后的结果；别人拿不到密码就登不上。
// GitHub token 只存本机钥匙串（改目录仓库时用）。
// 注意：App 里的管理员密码只管本机按钮显不显；真正把改动推到目录仓库，
// 靠的是 GitHub token（只有用户有），别人就算登上了这台手机的界面也推不动。

import SwiftUI
import CryptoKit
import Security

/// 管理员账号仓库：账号密码提前写好，只认这一个账号，没有注册。
@MainActor
final class AccountStore: ObservableObject {
    /// 提前写好的管理员账号（只有这一个能登入）。
    static let ownerUsername = "z5226858"
    /// 提前写好的管理员密码加密结果（SHA256，原文不在代码里）。
    static let ownerPasswordHash = "bda886f1482994b4872a7a4606fdf5ba604dabdc5aa19f2aa2a459b4abb1294a"

    @Published private(set) var currentUser: String?

    private let currentKey = "wallive-current-user"

    init() {
        // 只认提前写好的那一个账号，旧版本留下的登入名不算数。
        if let user = UserDefaults.standard.string(forKey: currentKey),
           user == Self.ownerUsername {
            currentUser = user
        } else {
            currentUser = nil
            UserDefaults.standard.removeObject(forKey: currentKey)
        }
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 登入：只认提前写好的那一个账号密码；不对都只报同一句。
    func login(username: String, password: String) -> String? {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard name == Self.ownerUsername, Self.hash(password) == Self.ownerPasswordHash
        else { return "账号或密码不对。" }
        currentUser = name
        UserDefaults.standard.set(name, forKey: currentKey)
        return nil
    }

    func logout() {
        currentUser = nil
        UserDefaults.standard.removeObject(forKey: currentKey)
    }

    // MARK: - GitHub token（钥匙串）

    private let tokenService = "wallive-catalog-token"
    private let tokenAccount = "owner"

    /// 读 token（只给改目录仓库的接口用，从不在界面上显示原文）。
    func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// 存 token（有旧的就覆盖）。
    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var attrs = query
            attrs[kSecValueData as String] = data
            SecItemAdd(attrs as CFDictionary, nil)
        }
    }

    func clearToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    var hasToken: Bool { loadToken() != nil }
}

/// 管理员页：没登入 → 登入表单（没有注册入口）；已登入 → 管理员页（含 token）。
/// store 不传就自己新建一个（目录页右上角人头按钮用共用的那一个）。
struct AccountView: View {
    @StateObject private var store: AccountStore

    init(store: AccountStore? = nil) {
        _store = StateObject(wrappedValue: store ?? AccountStore())
    }

    var body: some View {
        NavigationStack {
            if let user = store.currentUser {
                AdminPage(store: store, user: user)
            } else {
                LoginPage(store: store)
            }
        }
    }
}

/// 登入表单：只认提前写好的那一个账号，没有注册、找回入口。
private struct LoginPage: View {
    @ObservedObject var store: AccountStore
    @State private var username = ""
    @State private var password = ""
    @State private var error = ""

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("换一张壁纸，换一个心情")
                    .font(.title3).bold()
                Text("你好我好大家好")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
            TextField("账号", text: $username)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            Button("登入") {
                if let message = store.login(username: username, password: password) {
                    error = message
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(username.isEmpty || password.isEmpty)
            Text("只有提前写好的管理员账号能登入，没有注册入口。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .navigationTitle("登入")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 管理员页：登入后显示，含 GitHub token（改目录仓库时用，只存本机钥匙串）。
private struct AdminPage: View {
    @ObservedObject var store: AccountStore
    let user: String
    @State private var token = ""
    @State private var tokenSaved = false
    @State private var tokenNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("你好，\(user)").font(.title2).bold()
            Text("管理员").font(.subheadline)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.red).foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("登入后目录卡片上会出现改置顶、删除的按钮，还有增加壁纸的入口，只有你能看到、只有你能改；别人不用登入、直接进目录。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("GitHub 钥匙（改目录仓库时用）").font(.subheadline).bold()
                Text("去 GitHub 拿：Settings → Developer settings → Personal access tokens → Fine-grained，只勾 wallive-catalog、Contents 选 Read and write，生成后贴进来，填一次就行，只存这台手机的钥匙串里。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            Button("退出登入", role: .destructive) { store.logout() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .padding()
        .navigationTitle("我的账号")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tokenSaved = store.hasToken }
    }
}
