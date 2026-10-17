import Foundation

extension UserDefaults {
    /// A setting, or `fallback` when it was never set. Unlike `object(forKey:) as? Bool`, this
    /// also reads a value given as text, such as a launch argument (`-showWeekends YES`), the
    /// same way `@AppStorage` does, so code and views never disagree about a setting.
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }

    func integer(forKey key: String, default fallback: Int) -> Int {
        object(forKey: key) == nil ? fallback : integer(forKey: key)
    }
}
