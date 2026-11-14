import SwiftUI
import LocalAuthentication

/// Passcode / biometric gate shown before the export flow can be used.
struct AdminLoginView: View {
    var onUnlock: () -> Void
    @State private var reason = "管理员登录后才能导出已装壁纸"
    @State private var error: String?

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("管理员登录")
                .font(.title2.weight(.semibold))
            Text("导出已安装的壁纸前，请先通过管理员验证。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button {
                authenticate()
            } label: {
                Label("管理员登录", systemImage: "faceid")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .onAppear(perform: authenticate)
    }

    private func authenticate() {
        let ctx = LAContext()
        var evalError: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evalError) else {
            error = "设备未设置密码，无法进行管理员验证"
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async {
                if ok {
                    error = nil
                    onUnlock()
                } else {
                    error = "验证未通过，请重试"
                }
            }
        }
    }
}
