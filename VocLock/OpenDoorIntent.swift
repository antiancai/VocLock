import AppIntents
import Foundation

/// 快捷指令 / Siri / 操作按钮 / 锁屏小组件 的「开门」动作。
///
/// 关键点：`openAppWhenRun = false` —— 执行时不会把 App 切到前台，
/// 用户从锁屏、主屏、轻点背面或 Siri 触发都能直接开门。
/// 需要 Info.plist 里的 `UIBackgroundModes: bluetooth-central`，否则一旦不进前台
/// 蓝牙回调会被系统挂起，表现为「转圈到超时」。
struct OpenDoorIntent: AppIntent {

    static var title: LocalizedStringResource = "开宿舍门"

    static var description: IntentDescription = IntentDescription("不打开 App，直接连接宿舍门锁并开锁。")

    /// 不拉起 App，纯后台跑完
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let raw = KeychainStore.load("activationKey") ?? AppConfig.defaultKey
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard key.count == 32, key.allSatisfy({ $0.isHexDigit }) else {
            return .result(dialog: "还没有保存钥匙：先打开一次 App，在「钥匙」里粘贴 32 位 activationKey。")
        }

        let ok = await LockSession.shared.unlockAndWait(key: key)
        if ok {
            return .result(dialog: "已开门")
        }
        return .result(dialog: "开门失败，靠近门口再试一次。")
    }
}

/// 让「开门」出现在快捷指令的推荐里，也支持直接对 Siri 说
struct VocLockShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenDoorIntent(),
            phrases: [
                "用\(.applicationName)开宿舍门",
                "\(.applicationName)开门"
            ],
            shortTitle: "开门",
            systemImageName: "door.left.hand.open"
        )
    }
}
