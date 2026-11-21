import Foundation

/// Test runs only (`-HongguoFixtureDelay <seconds>` with the offline sample rows): each sample
/// request waits that long and its titles name the tab they were loaded for, so a spinner, a slow
/// reply or a reply landing on the wrong tab can be seen. Without the argument nothing changes.
public enum FixtureDebug {
    public static var delay: Double { UserDefaults.standard.double(forKey: "HongguoFixtureDelay") }
    public static func wait() async {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    }
    public static func title(_ title: String, tab: String) -> String {
        delay > 0 && !tab.isEmpty ? "【\(tab)】\(title)" : title
    }
}
