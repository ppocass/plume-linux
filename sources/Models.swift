import Foundation

// La gestion des modeles : lister, telecharger, choisir.
//
// Sur macOS, c'est la page « Modeles » de l'app (ModelsView.swift) qui fait
// cela, avec une barre de progression. Ici, c'est une commande : `plume
// models`. Le catalogue est le MEME (ModelCatalog.swift, non modifie) : les
// cinq modeles de Plume sont disponibles.
//
// Deux differences assumees avec macOS :
//  - Parakeet n'existe pas sous Linux (il tourne sur le Neural Engine via
//    Core ML). On ne le propose donc pas : le catalogue est filtre.
//  - Le telechargement passe par le ModelStore de Plume (sha256 verifie),
//    mais les modeles Parakeet sont ecartes avant.

enum ModelsCLI {

    /// Les modeles utilisables sous Linux. Parakeet est exclu : FluidAudio
    /// s'appuie sur Core ML, qui n'existe que sur Apple.
    static var available: [ModelInfo] {
        ModelCatalog.all.filter { $0.family != .parakeet }
    }

    static func run(_ args: [String]) {
        // Poser la langue avant le moindre appel a L().
        UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        let sub = args.first ?? "list"

        switch sub {
        case "list":
            list()

        case "use":
            guard let id = args.dropFirst().first else {
                FileHandle.standardError.write(Data("usage : plume models use <id>\n".utf8))
                exit(1)
            }
            use(id)

        case "download":
            guard let id = args.dropFirst().first else {
                FileHandle.standardError.write(Data("usage : plume models download <id>\n".utf8))
                exit(1)
            }
            download(id)

        case "current":
            print("modele actif : \(selectedID)")

        default:
            list()
        }
    }

    /// Le modele choisi, garde au meme endroit que sur macOS (UserDefaults).
    static var selectedID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "model") ?? ""
            if !stored.isEmpty, available.contains(where: { $0.id == stored }) {
                return stored
            }
            return "whisper-turbo-q5"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "model")
        }
    }

    /// La langue de l'interface. Sans locale configuree (serveur, SSH), la
    /// detection rend « en » et tout sort en anglais. Plume est francophone :
    /// on prend le francais par defaut, et PLUME_LANG=fr|en force l'autre.
    static var language: AppLanguage {
        if let forced = ProcessInfo.processInfo.environment["PLUME_LANG"],
           let l = AppLanguage(rawValue: forced) {
            return l
        }
        return .fr
    }

    private static func list() {
        UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        let current = selectedID
        print("")
        print("  Modeles disponibles sous Linux")
        print("  " + String(repeating: "─", count: 62))
        for m in available {
            let mark = m.id == current ? "●" : "○"
            let size = formatBytes(m.downloadSize)
            // installedFolder verifie que CHAQUE fichier est la, avec la bonne
            // taille : un dossier vide ne compte pas comme installe.
            let installed = ModelLocation.installedFolder(m) != nil
            let state = installed ? "installé" : "à télécharger"
            print("  \(mark) \(m.id)")
            print("      \(m.name) — \(size), \(state)")
            print("      \(m.summary)")
            print("")
        }
        print("  plume models use <id>        choisir un modele")
        print("  plume models download <id>   telecharger un modele")
        print("")
        print("  (« En ligne » ne se telecharge pas : c'est un service distant,")
        print("   avec ta propre cle API, configuree dans ~/.config/plume/local.json)")
        print("")
    }

    private static func use(_ id: String) {
        guard let m = available.first(where: { $0.id == id }) else {
            FileHandle.standardError.write(Data("modele inconnu : \(id)\n".utf8))
            FileHandle.standardError.write(Data("essaie : plume models\n".utf8))
            exit(1)
        }
        let folder = ModelLocation.plumeFolder(m)
        let installed = FileManager.default.fileExists(atPath: folder.path)
        if !installed {
            FileHandle.standardError.write(
                Data("\(m.name) n'est pas encore telecharge.\n".utf8))
            FileHandle.standardError.write(
                Data("lance : plume models download \(m.id)\n".utf8))
            exit(1)
        }
        selectedID = m.id
        print("modele actif : \(m.name) (\(m.id))")
        print("")
        print("  Le port du moteur change : \(m.port).")
        print("  Si le service systemd ne correspond pas, ajuste")
        print("  ~/.config/systemd/user/plume-engine.service.")
    }

    private static func download(_ id: String) {
        guard let m = available.first(where: { $0.id == id }) else {
            FileHandle.standardError.write(Data("modele inconnu : \(id)\n".utf8))
            exit(1)
        }
        print("Telechargement de \(m.name) — \(formatBytes(m.downloadSize))…")

        // ModelStore.install() verifie le sha256 de chaque fichier, exactement
        // comme sur macOS. On l'appelle depuis une tache, en affichant la
        // progression.
        var lastPercent = -1
        let done = DispatchSemaphore(value: 0)
        var failure: String?

        // Telechargement via curl, pas URLSession.
        //
        // ⚠️ Bug de fondation Swift sous Linux : un URLSession en mode
        // telechargement avec delegate provoque au moment de sa liberation
        //     « Object of class _MultiHandle deallocated with non-zero retain
        //      count » puis abort (code 134).
        // Mesure ici : le fichier arrive bien (1,6 Go) mais le processus meurt
        // AVANT le deplacement final, donc le modele n'est jamais installe.
        // curl fait le meme travail, en flux, et ne meurt pas.
        let fm = FileManager.default
        let folder = ModelLocation.plumeFolder(m)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
        for file in m.files {
            let dest = folder.appendingPathComponent(file.path)
            if let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value,
               size == file.size {
                continue   // deja la, a la bonne taille
            }
            let part = dest.appendingPathExtension("part")
            try? fm.removeItem(at: part)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)

            let url = m.url(for: file).absoluteString
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-fL", "--progress-bar", "-o", part.path, url]
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                try? fm.removeItem(at: part)
                failure = "curl a echoue (code \(p.terminationStatus)) sur \(file.path)"
                done.signal()
                return
            }

            // Le sha256, exactement comme sur macOS : un modele corrompu est
            // refuse plutot que charge.
            let actual = (try? ModelDownloader.sha256(of: part)) ?? ""
            guard actual == file.sha256 else {
                try? fm.removeItem(at: part)
                failure = "fichier corrompu : \(file.path) (sha256 \(actual.prefix(12))… au lieu de \(file.sha256.prefix(12))…)"
                done.signal()
                return
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: part, to: dest)
        }
        FileHandle.standardError.write(Data("\r  100 %\n".utf8))
        } catch {
            failure = error.localizedDescription
            done.signal()
            return
        }

        if let failure {
            FileHandle.standardError.write(Data("echec : \(failure)\n".utf8))
            exit(1)
        }
        print("\(m.name) installe.")
        if selectedID != m.id {
            print("Pour l'utiliser : plume models use \(m.id)")
        }
    }
}
