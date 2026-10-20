import Combine
import Foundation

/// 存在 UserDefaults 的設定值；用在 ObservableObject 內，變動時自動通知畫面更新。
@propertyWrapper
struct Stored<Value> {
    let key: String
    let defaultValue: Value

    init(_ key: String, _ defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    @available(*, unavailable, message: "@Stored 只能用在 ObservableObject 類別內")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    static subscript<Instance: ObservableObject>(
        _enclosingInstance instance: Instance,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Instance, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Instance, Stored<Value>>
    ) -> Value {
        get {
            let wrapper = instance[keyPath: storageKeyPath]
            return UserDefaults.standard.object(forKey: wrapper.key) as? Value ?? wrapper.defaultValue
        }
        set {
            let wrapper = instance[keyPath: storageKeyPath]
            (instance.objectWillChange as? ObservableObjectPublisher)?.send()
            UserDefaults.standard.set(newValue, forKey: wrapper.key)
        }
    }
}
