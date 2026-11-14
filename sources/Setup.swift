import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// Réglages propres à un Mac, hors de l'app et du dépôt :
/// `~/.config/plume/local.json`. Sans ce fichier, Plume se comporte comme la
/// version téléchargée (moteurs rangés dans l'app, modèles téléchargés,
/// nettoyage avec sa propre clé API, vocabulaire vide).
///
/// Toutes les clés sont facultatives :
/// ```json
/// {
///   "polish": { "name": "My server", "url": "http://10.0.0.2:3001/v1/chat/completions",
///               "model": "my-model", "keyFile": "~/.config/my-server/key", "reasoning": true },
///   "whisper": { "binary": "/opt/homebrew/bin/whisper-server", "model": "~/models/ggml-large-v3-turbo-q5_0.bin" },
///   "parakeetBinary": "~/bin/parakeet-server",
///   "sharedEngineNote": { "fr": "…", "en": "…" },
///   "vocabularySeed": [ { "word": "Plume", "variants": ["plum"] } ],
///   "bundleIdentifier": "…", "signingIdentity": "…"
/// }
/// ```
/// Les deux dernières ne servent qu'à `make-app.sh` / `make-dmg.sh`.
struct LocalConfig: Decodable {
    /// Le port du moteur, choisi a l'installation. Sous Linux, 8090 est
    /// souvent deja pris (Docker, crowdsec) : install.sh ecrit ici le port
    /// retenu, pour que le binaire et le service systemd soient d'accord sans
    /// dependre d'une variable d'environnement (un raccourci du bureau n'en a
    /// pas).
    var enginePort: Int?
    struct Polish: Decodable {
        var name: String?
        var url: String
        var model: String
        var keyFile: String?
        var reasoning: Bool?
    }
    struct Whisper: Decodable {
        var binary: String?
        var model: String?
    }
    struct Text: Decodable {
        var fr: String
        var en: String
    }
    struct Seed: Decodable {
        var word: String
        var variants: [String]?
    }

    var polish: Polish?
    var whisper: Whisper?
    var parakeetBinary: String?
    var sharedEngineNote: Text?
    var vocabularySeed: [Seed]?

    static let url: URL = {
        if let path = ProcessInfo.processInfo.environment["PLUME_LOCAL_CONFIG"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/plume/local.json")
    }()

    /// `nil` si le fichier manque, est illisible, ou si on simule un autre Mac.
    static let current: LocalConfig? = {
        guard !Setup.simulatePortable, let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(LocalConfig.self, from: data)
        } catch {
            Log.info("local.json ignored: \(error.localizedDescription)")
            return nil
        }
    }()

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

/// Ce que Plume trouve sur le Mac où elle tourne.
enum Setup {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let fm = FileManager.default

    /// `PLUME_DEMO=1` : pour les captures d'écran — pas de raccourci, pas
    /// d'ouverture de session ni de mise à jour, autorisations affichées comme
    /// accordées. À lancer avec `PLUME_DATA_DIR` vers des données de démo.
    static let demo = ProcessInfo.processInfo.environment["PLUME_DEMO"] == "1"

    /// `PLUME_PORTABLE=1` : se comporter comme sur un Mac neuf (tests, captures).
    static let simulatePortable = ProcessInfo.processInfo.environment["PLUME_PORTABLE"] == "1"

    /// Historique, vocabulaire et modèles. `PLUME_DATA_DIR` le déplace (tests).
    static let dataFolder: URL = {
        let dir: URL
        if let custom = ProcessInfo.processInfo.environment["PLUME_DATA_DIR"] {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Plume", isDirectory: true)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var modelsFolder: URL {
        let dir = dataFolder.appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Le serveur de nettoyage de `local.json`, si son fichier de clé existe.
    static var localPolish: LocalConfig.Polish? {
        guard let p = LocalConfig.current?.polish else { return nil }
        if let keyFile = p.keyFile, !fm.fileExists(atPath: LocalConfig.expand(keyFile)) { return nil }
        return p
    }

    /// Texte sous la section Moteur (par exemple les autres apps qui le partagent).
    static var sharedEngineNote: String? {
        LocalConfig.current?.sharedEngineNote.map { L($0.fr, $0.en) }
    }

    private static func bundled(_ name: String) -> String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)").path
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    /// `local.json` d'abord (moteur partagé avec d'autres apps), sinon la copie rangée dans Plume.app.
    static var parakeetBinary: String? {
        if let p = LocalConfig.current?.parakeetBinary.map(LocalConfig.expand), fm.isExecutableFile(atPath: p) { return p }
        return bundled("parakeet-server")
    }

    static var whisperBinary: String? {
        if let p = LocalConfig.current?.whisper?.binary.map(LocalConfig.expand), fm.isExecutableFile(atPath: p) { return p }
        return bundled("whisper-server")
    }

    /// Un fichier de modèle Whisper donné par `local.json` (utilisé à la place
    /// du modèle du catalogue qui porte le même nom).
    static var localWhisperModel: URL? {
        guard let p = LocalConfig.current?.whisper?.model.map(LocalConfig.expand), fm.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Là où FluidAudio range les modèles qu'il télécharge lui-même. Plume en
    /// réutilise la copie plutôt que de la télécharger deux fois.
    static var fluidAudioModels: URL {
        home.appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    /// Mémoire du Mac en Go (8, 16, 24…).
    static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// "Apple M1", "Apple M3 Pro"…
    static var chipName: String {
        #if canImport(Darwin)
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
        #else
        guard let text = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else { return "" }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("model name") {
            return line.split(separator: ":", maxSplits: 1)
                .last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        return ""
        #endif
    }

    /// Puce Pro, Max ou Ultra (plus de cœurs graphiques pour Whisper).
    static var isProChip: Bool {
        let name = chipName
        return name.contains("Pro") || name.contains("Max") || name.contains("Ultra")
    }

    static var macOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// Mémoire libre ou récupérable tout de suite, en Go (pages libres,
    /// inactives, purgeables). Relevée une fois au lancement : le conseil de
    /// modèle ne doit pas changer d'une minute à l'autre.
    static let availableMemoryGB: Double = {
        #if canImport(Darwin)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Double(memoryGB) / 2 }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
            + UInt64(stats.speculative_count)
        return Double(pages) * Double(vm_kernel_page_size) / 1_073_741_824
        #else
        // /proc/meminfo : MemAvailable est deja « libre + recuperable tout de
        // suite », exactement ce que le calcul mach fait a la main sur macOS.
        guard let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else {
            return Double(memoryGB) / 2
        }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("MemAvailable:") {
            let kb = line.split(separator: " ").dropFirst().compactMap { Double($0) }.first
            if let kb { return kb * 1024 / 1_073_741_824 }
        }
        return Double(memoryGB) / 2
        #endif
    }()

    /// La langue du Mac (« fr », « en »…).
    static var systemLanguage: String {
        // Sous Linux, la langue se lit a trois endroits, dans cet ordre :
        //   1. LC_ALL / LANG de l'environnement (le plus proche de l'actuel)
        //   2. /etc/default/locale ou /etc/locale.conf — ce que la distribution
        //      a enregistre quand l'utilisateur a choisi sa langue. C'est la
        //      source la plus fiable : une session SSH ou un raccourci du
        //      bureau n'heritent pas toujours de LANG.
        //   3. Locale.preferredLanguages, qui rend « en » par defaut.
        // Faute de tout cela, Plume est francophone : francais.
        func code(_ raw: String) -> String? {
            let v = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'")))
            guard v.count >= 2 else { return nil }
            let c = String(v.prefix(2)).lowercased()
            return (c == "c" || c == "po" || !c.allSatisfy(\.isLetter)) ? nil : c
        }

        for key in ["LC_ALL", "LANG", "LC_MESSAGES"] {
            if let v = ProcessInfo.processInfo.environment[key], let c = code(v) { return c }
        }

        for path in ["/etc/default/locale", "/etc/locale.conf"] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].hasPrefix("LANG") || parts[0].hasPrefix("LC_ALL") else { continue }
                if let c = code(String(parts[1])) { return c }
            }
        }

        let preferred = String((Locale.preferredLanguages.first ?? "fr").prefix(2)).lowercased()
        return preferred == "en" ? "fr" : preferred
    }
}

/// Les clés API, dans le trousseau (jamais dans les réglages ni dans le journal).
/// Sous Linux il n'y a pas de trousseau : un fichier en 0600 dans le dossier de
/// configuration, ce que font toutes les apps de bureau quand Secret Service
/// n'est pas disponible.
enum KeychainStore {
    #if canImport(Security)
    private static var service: String { (Bundle.main.bundleIdentifier ?? "plume") + ".polish" }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s.isEmpty ? nil : s
    }

    static func write(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
    #else
    private static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/plume/keys", isDirectory: true)
    }
    private static func file(_ account: String) -> URL {
        folder.appendingPathComponent(account.replacingOccurrences(of: "/", with: "_"))
    }
    static func read(_ account: String) -> String? {
        guard let s = try? String(contentsOf: file(account), encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    static func write(_ account: String, _ value: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = file(account)
        if value.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? value.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    #endif
}

/// Les adresses joignables sans HTTPS : ce Mac et les réseaux privés
/// seulement. Tout ce qui est sur Internet doit être en HTTPS (la clé API et
/// le texte partent avec la requête).
enum EndpointPolicy {
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return isLocal(host)
    }

    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true   // plage CGNAT des réseaux privés virtuels (Tailscale…)
        case (169, 254): return true
        default: return false
        }
    }
}
