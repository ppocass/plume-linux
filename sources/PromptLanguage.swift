import Foundation

// Recopie de Prefs.swift (fichier SwiftUI), a l'identique : la couche
// logique en a besoin et ne doit pas dependre de l'interface.

enum PromptLanguage: String, CaseIterable, Identifiable {
    case auto, fr, en
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return L("Automatique", "Automatic")
        case .fr: return "Français"
        case .en: return "English"
        }
    }

    /// Automatique : français si l'on dicte en français, anglais pour les
    /// autres langues ; en détection automatique, la langue de l'interface.
    static func resolved(for language: DictationLanguage) -> PromptLanguage {
        let stored = PromptLanguage(rawValue: UserDefaults.standard.string(forKey: "polishPrompt") ?? "") ?? .auto
        guard stored == .auto else { return stored }
        switch language {
        case .fr: return .fr
        case .auto: return AppLanguage.current == .fr ? .fr : .en
        default: return .en
        }
    }
}
