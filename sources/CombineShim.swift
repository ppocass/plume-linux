import Foundation

// Combine n'existe pas dans la toolchain Linux. Le code de Plume n'utilise
// ObservableObject et @Published que comme marqueurs pour SwiftUI : il ne
// touche jamais a objectWillChange, aux projections `$`, ni a sink/assign.
// Ces declarations vides suffisent pour la couche logique.
#if !canImport(Combine)

public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(initialValue: Value) { self.wrappedValue = initialValue }
}

#endif
