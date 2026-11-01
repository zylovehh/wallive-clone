// AccountView.swift
// 登入页 + 注册页 + 找回密码页。
// 密码不存原文，只存加密后的结果；第一个注册的账号就是管理员，
// 管理员改置顶、下载数要改目录表 catalog.json 里的 pinned、downloads 字段，
// 推到仓库后对所有人生效。

import SwiftUI
import CryptoKit

/// 账号仓库：账号名 → 密码加密结果、找回暗号加密结果、是不是管理员。
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var currentUser: String?
    @Published private(set) var isAdmin = false

    private let accountsKey = "wallive-accounts"
    private let currentKey = "wallive-current-user"

    struct Account: Codable {
        let passwordHash: String
        let answerHash: String
        let isAdmin: Bool
    }

    init() {
        currentUser = UserDefaults.standard.string(forKey: currentKey)
        if let user = currentUser {
            isAdmin = loadAccounts()[user]?.isAdmin ?? false
        }
    }

    private func loadAccounts() -> [String: Account] {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let accounts = try? JSONDecoder().decode([String: Account].self, from: data)
        else { return [:] }
        return accounts
    }

    private func saveAccounts(_ accounts: [String: Account]) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 注册：账号名、密码、找回暗号都不能为空；账号已存在就报错；
    /// 第一个注册的账号自动成为管理员。
    func register(username: String, password: String, answer: String) -> String? {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !password.isEmpty, !answer.isEmpty else {
            return "账号、密码、找回暗号都不能空。"
        }
        var accounts = loadAccounts()
        guard accounts[name] == nil else { return "这个账号已经注册过了，直接登入就行。" }
        accounts[name] = Account(
            passwordHash: Self.hash(password),
            answerHash: Self.hash(answer),
            isAdmin: accounts.isEmpty)
        saveAccounts(accounts)
        currentUser = name
        isAdmin = accounts[name]?.isAdmin ?? false
        UserDefaults.standard.set(name, forKey: currentKey)
        return nil
    }

    /// 登入：账号不存在或密码不对都只报同一句，不透露是哪一项错了。
    func login(username: String, password: String) -> String? {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard let account = loadAccounts()[name],
              account.passwordHash == Self.hash(password)
        else { return "账号或密码不对。" }
        currentUser = name
        isAdmin = account.isAdmin
        UserDefaults.standard.set(name, forKey: currentKey)
        return nil
    }

    /// 找回密码：账号 + 注册时设的找回暗号对上，才能设新密码。
    func resetPassword(username: String, answer: String, newPassword: String) -> String? {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !newPassword.isEmpty else { return "新密码不能为空。" }
        var accounts = loadAccounts()
        guard var account = accounts[name],
              account.answerHash == Self.hash(answer)
        else { return "账号或找回暗号不对。" }
        account = Account(
            passwordHash: Self.hash(newPassword),
            answerHash: account.answerHash, isAdmin: account.isAdmin)
        accounts[name] = account
        saveAccounts(accounts)
        return nil
    }

    func logout() {
        currentUser = nil
        isAdmin = false
        UserDefaults.standard.removeObject(forKey: currentKey)
    }
}

/// 登入页：登入表单 + 去注册、去找回密码的入口；已登入就显示账号页。
/// store 不传就自己新建一个（目录页右上角弹出的登入用这个）；
/// onSkip 不为空时登入页底部多一个“先逛逛”按钮（开场 Hello 动画后进登入页用这个，
/// 不想登入也能先进目录，之后右上角人头按钮还能再登入）。
struct AccountView: View {
    @StateObject private var store: AccountStore
    var onSkip: (() -> Void)?

    init(store: AccountStore? = nil, onSkip: (() -> Void)? = nil) {
        _store = StateObject(wrappedValue: store ?? AccountStore())
        self.onSkip = onSkip
    }

    @State private var page = "login" // login、register、forgot

    var body: some View {
        NavigationStack {
            if let user = store.currentUser {
                accountPage(user: user)
            } else if page == "register" {
                RegisterPage(store: store, onDone: { page = "login" })
            } else if page == "forgot" {
                ForgotPage(store: store, onDone: { page = "login" })
            } else {
                LoginPage(store: store, onRegister: { page = "register" }, onForgot: { page = "forgot" }, onSkip: onSkip)
            }
        }
    }

    private func accountPage(user: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("你好，\(user)").font(.title2).bold()
            if store.isAdmin {
                Text("管理员").font(.subheadline)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.red).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("管理员置顶、下载数改目录表 catalog.json 里的 pinned、downloads 字段，推到仓库后对所有人生效。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("退出登入", role: .destructive) { store.logout() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .padding()
        .navigationTitle("我的账号")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 登入表单。
private struct LoginPage: View {
    @ObservedObject var store: AccountStore
    let onRegister: () -> Void
    let onForgot: () -> Void
    var onSkip: (() -> Void)?
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
            HStack {
                Button("没有账号？去注册", action: onRegister)
                Spacer()
                Button("忘记密码", action: onForgot)
            }
            .font(.subheadline)
            if let onSkip {
                Button("先逛逛，去目录", action: onSkip)
                    .font(.subheadline)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("登入")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 注册表单：账号、密码、找回暗号（找回密码时要用，自己记住）。
private struct RegisterPage: View {
    @ObservedObject var store: AccountStore
    let onDone: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var answer = ""
    @State private var error = ""
    @State private var done = false

    var body: some View {
        VStack(spacing: 16) {
            TextField("账号", text: $username)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField("再输一次密码", text: $confirm)
                .textFieldStyle(.roundedBorder)
            TextField("找回暗号（找回密码时要用）", text: $answer)
                .textFieldStyle(.roundedBorder)
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            if done { Text("注册好了，已自动登入。").foregroundStyle(.green).font(.caption) }
            Button("注册") {
                guard password == confirm else { error = "两次密码不一样。"; return }
                if let message = store.register(username: username, password: password, answer: answer) {
                    error = message
                } else {
                    done = true
                    error = ""
                }
            }
            .buttonStyle(.borderedProminent)
            Button("已有账号？去登入", action: onDone)
                .font(.subheadline)
            Spacer()
        }
        .padding()
        .navigationTitle("注册")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 找回密码表单：账号 + 找回暗号对上，才能设新密码。
private struct ForgotPage: View {
    @ObservedObject var store: AccountStore
    let onDone: () -> Void
    @State private var username = ""
    @State private var answer = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var error = ""
    @State private var done = false

    var body: some View {
        VStack(spacing: 16) {
            TextField("账号", text: $username)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
            TextField("找回暗号", text: $answer)
                .textFieldStyle(.roundedBorder)
            SecureField("新密码", text: $newPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("再输一次新密码", text: $confirm)
                .textFieldStyle(.roundedBorder)
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            if done { Text("密码改好了，去登入吧。").foregroundStyle(.green).font(.caption) }
            Button("改密码") {
                guard newPassword == confirm else { error = "两次新密码不一样。"; return }
                if let message = store.resetPassword(username: username, answer: answer, newPassword: newPassword) {
                    error = message
                } else {
                    done = true
                    error = ""
                }
            }
            .buttonStyle(.borderedProminent)
            Button("想起来了？去登入", action: onDone)
                .font(.subheadline)
            Spacer()
        }
        .padding()
        .navigationTitle("找回密码")
        .navigationBarTitleDisplayMode(.inline)
    }
}
