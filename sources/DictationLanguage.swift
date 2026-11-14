import Foundation

// Recopie de Prefs.swift (fichier SwiftUI), a l'identique : la couche
// logique en a besoin et ne doit pas dependre de l'interface.

enum DictationLanguage: String, CaseIterable, Identifiable {
    case auto, fr, en, es, de, it, pt
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return L("Détection automatique (recommandé)", "Automatic detection (recommended)")
        case .fr: return L("Français", "French")
        case .en: return L("Anglais", "English")
        case .es: return L("Espagnol", "Spanish")
        case .de: return L("Allemand", "German")
        case .it: return L("Italien", "Italian")
        case .pt: return L("Portugais", "Portuguese")
        }
    }
    /// Nom de la langue pour la consigne anglaise du nettoyage.
    var promptNameEN: String {
        switch self {
        case .auto: return "in its original language (often English or French, sometimes another one). Keep that language, never translate"
        case .fr: return "in French"
        case .en: return "in English"
        case .es: return "in Spanish"
        case .de: return "in German"
        case .it: return "in Italian"
        case .pt: return "in Portuguese"
        }
    }
    /// Nom de la langue pour la consigne du lissage.
    var promptName: String {
        switch self {
        case .auto: return "dans sa langue d'origine (souvent le français ou l'anglais, parfois une autre) — garde-la telle quelle, ne traduis jamais"
        case .fr: return "en français"
        case .en: return "en anglais"
        case .es: return "en espagnol"
        case .de: return "en allemand"
        case .it: return "en italien"
        case .pt: return "en portugais"
        }
    }
}

