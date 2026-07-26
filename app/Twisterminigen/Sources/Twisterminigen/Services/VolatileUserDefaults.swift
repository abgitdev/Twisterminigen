#if DEBUG
import Foundation

/// In-memory `UserDefaults` used by test-only construction paths.
///
/// The superclass provides Foundation's typed accessors while every mutation and lookup is
/// redirected to process memory. No CFPreferences application domain or plist is written.
final class VolatileUserDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any]
    private var registrations: [String: Any] = [:]

    init(_ initialValues: [String: Any] = [:]) {
        values = initialValues
        super.init(suiteName: "com.twisterminigen.volatile.\(UUID().uuidString)")!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock {
            values[defaultName] ?? registrations[defaultName]
        }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        _ = lock.withLock {
            if let value {
                values[defaultName] = value
            } else {
                values.removeValue(forKey: defaultName)
            }
        }
    }

    override func removeObject(forKey defaultName: String) {
        _ = lock.withLock {
            values.removeValue(forKey: defaultName)
        }
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        lock.withLock {
            registrations.merge(registrationDictionary) { existing, _ in existing }
        }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock {
            registrations.merging(values) { _, explicit in explicit }
        }
    }
}
#endif
