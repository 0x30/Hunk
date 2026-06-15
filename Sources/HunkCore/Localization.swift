import Foundation

/// HunkCore 的本地化注入点。
///
/// core 层够不到 app 层的 `tr()`（语言设置在 app 的 SettingsStore），所以这里留一个
/// 注入点：app 启动时把翻译器塞进来（`CoreLocale.translate = { zh, en in tr(zh, en) }`）。
/// 未注入时默认返回中文——保证 core 单独使用 / 测试时也有合理输出。
public enum CoreLocale {
    public static var translate: (String, String) -> String = { zh, _ in zh }
}

/// core 层翻译快捷函数，与 app 层 `tr` 同形：`ctr("中文", "English")`。
func ctr(_ zh: String, _ en: String) -> String {
    CoreLocale.translate(zh, en)
}
