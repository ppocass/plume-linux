#!/usr/bin/env python3
"""Adapte la logique de Plume (ecrite pour macOS) pour qu'elle compile sous Linux.

Chaque retouche est minimale et explicite : on ne reecrit rien, on donne a
Linux l'equivalent de ce qu'Apple fournit ailleurs. Le depot d'origine n'est
jamais modifie : on travaille sur la copie dans ~/plume-linux/Sources/PlumeLinux.

Les six differences reelles entre macOS et Linux, mesurees pendant le portage :

  1. CryptoKit   -> swift-crypto            (meme API, paquet Apple, MIT)
  2. Foundation  -> FoundationNetworking    (URLSession/URLRequest y vivent)
  3. mach/sysctl -> /proc                   (meminfo, cpuinfo, stat, exe)
  4. Security    -> fichier 0600            (~/.config/plume/keys)
  5. Combine     -> declarations vides      (ObservableObject, @Published)
  6. trashItem   -> specification XDG       (~/.local/share/Trash)

Le script est idempotent : chaque motif est cherche avant d'etre remplace, et
un motif deja transforme n'est pas retransforme.
"""

import pathlib
import sys

SRC = pathlib.Path.home() / "plume-linux" / "Sources" / "PlumeLinux"
ORIG = pathlib.Path.home() / "plume-linux-orig" / "Plume" / "Sources" / "Plume"

stats = {"ok": 0, "miss": 0}


def patch(name, pairs, required=True):
    p = SRC / name
    if not p.exists():
        print(f"  ! {name} absent")
        return
    s = p.read_text()
    n = 0
    for old, new in pairs:
        if new in s:          # deja applique
            continue
        if old in s:
            s = s.replace(old, new, 1)
            n += 1
        elif required:
            stats["miss"] += 1
            print(f"  ! {name} : motif introuvable -> {old.splitlines()[0][:60]!r}")
    if n:
        p.write_text(s)
        stats["ok"] += n
        print(f"  {name} : {n} retouche(s)")


# --- 2. FoundationNetworking ------------------------------------------------
NET = ("import Foundation\n",
       "import Foundation\n#if canImport(FoundationNetworking)\n"
       "import FoundationNetworking\n#endif\n")
for f in ["SpeechEngine.swift", "ModelStore.swift", "Polisher.swift",
          "CloudTranscriber.swift", "Setup.swift"]:
    patch(f, [NET], required=False)

# --- 1. CryptoKit -----------------------------------------------------------
patch("ModelStore.swift", [
    ("import CryptoKit", "#if canImport(CryptoKit)\nimport CryptoKit\n#else\nimport Crypto\n#endif"),
])

# --- 0. L10n : AppKit ne sert qu'a AppAppearance.apply() --------------------
patch("L10n.swift", [
    ("import AppKit", "import Foundation"),
    ("    @MainActor func apply() {",
     "    #if canImport(AppKit)\n    @MainActor func apply() {"),
    ("        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)\n        }\n    }",
     "        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)\n        }\n    }\n    #endif"),
])

# --- 4. Security : le trousseau devient un fichier 0600 ---------------------
patch("Setup.swift", [
    ("#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\nimport Security\n",
     "#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n#if canImport(Security)\nimport Security\n#endif\n"),
    ("""/// Les clés API, dans le trousseau (jamais dans les réglages ni dans le journal).
enum KeychainStore {""",
     """/// Les clés API, dans le trousseau (jamais dans les réglages ni dans le journal).
/// Sous Linux il n'y a pas de trousseau : un fichier en 0600 dans le dossier de
/// configuration, ce que font toutes les apps de bureau quand Secret Service
/// n'est pas disponible.
enum KeychainStore {
    #if canImport(Security)"""),
    ("""        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}""",
     """        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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
}"""),
])

# --- 3. mach : memoire et processeur ----------------------------------------
patch("Setup.swift", [
    ("""    static let availableMemoryGB: Double = {
        var stats = vm_statistics64()""",
     """    static let availableMemoryGB: Double = {
        #if canImport(Darwin)
        var stats = vm_statistics64()"""),
    ("""        return Double(pages) * Double(vm_kernel_page_size) / 1_073_741_824
    }()""",
     """        return Double(pages) * Double(vm_kernel_page_size) / 1_073_741_824
        #else
        // /proc/meminfo : MemAvailable est deja « libre + recuperable tout de
        // suite », exactement ce que le calcul mach fait a la main sur macOS.
        guard let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else {
            return Double(memoryGB) / 2
        }
        for line in text.split(whereSeparator: \\.isNewline) where line.hasPrefix("MemAvailable:") {
            let kb = line.split(separator: " ").dropFirst().compactMap { Double($0) }.first
            if let kb { return kb * 1024 / 1_073_741_824 }
        }
        return Double(memoryGB) / 2
        #endif
    }()"""),
    ("""    static var chipName: String {
        var size = 0""",
     """    static var chipName: String {
        #if canImport(Darwin)
        var size = 0"""),
    ("""        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }""",
     """        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
        #else
        guard let text = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else { return "" }
        for line in text.split(whereSeparator: \\.isNewline) where line.hasPrefix("model name") {
            return line.split(separator: ":", maxSplits: 1)
                .last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        return ""
        #endif
    }"""),
])

# --- 3 bis. processus : /proc remplace sysctl et proc_pidpath ---------------
patch("SpeechEngine.swift", [
    ("""    nonisolated static func listenerPID(port: Int) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\\(port)", "-sTCP:LISTEN", "-t"]""",
     """    nonisolated static func listenerPID(port: Int) -> pid_t? {
        #if canImport(Darwin)
        let tool = "/usr/sbin/lsof"
        let toolArgs = ["-nP", "-iTCP:\\(port)", "-sTCP:LISTEN", "-t"]
        #else
        // ss fait partie d'iproute2, present sur toute distribution de bureau.
        let tool = "/usr/bin/ss"
        let toolArgs = ["-lptnH", "sport = :\\(port)"]
        #endif
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = toolArgs"""),
    ("""        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \\.isNewline).first.flatMap { pid_t($0) }
    }""",
     """        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #if canImport(Darwin)
        return text.split(whereSeparator: \\.isNewline).first.flatMap { pid_t($0) }
        #else
        // ss ecrit : users:(("whisper-server",pid=1234,fd=3))
        guard let range = text.range(of: "pid=") else { return nil }
        return pid_t(text[range.upperBound...].prefix { $0.isNumber })
        #endif
    }"""),
    ("""        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }""",
     """        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
        #else
        // /proc/<pid>/stat : le 4e champ est le PID du parent. Le 2e (le nom
        // du programme) peut contenir des espaces et des parentheses : on se
        // cale sur la derniere parenthese fermante.
        guard let text = try? String(contentsOfFile: "/proc/\\(pid)/stat", encoding: .utf8),
              let close = text.lastIndex(of: ")") else { return nil }
        let fields = text[text.index(after: close)...]
            .split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        return pid_t(fields[1])
        #endif
    }"""),
    ("""        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        // Comparé au chemin résolu (Homebrew : le binaire est un lien vers le Cellar).
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }""",
     """        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        // Comparé au chemin résolu (Homebrew : le binaire est un lien vers le Cellar).
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        #else
        // /proc/<pid>/exe est un lien vers le binaire reel.
        let link = "/proc/\\(pid)/exe"
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        #endif
    }"""),
    ("Int(Prefs.idleSeconds)", "Int(SpeechEngine.defaultIdleSeconds)"),
    ("""    let model: ModelInfo
    init(model: ModelInfo) { self.model = model }""",
     """    let model: ModelInfo
    init(model: ModelInfo) { self.model = model }

    /// Meme reglage et meme defaut que Prefs.idleSeconds (35 s), lu sans
    /// dependre du fichier SwiftUI.
    nonisolated static var defaultIdleSeconds: Double {
        let v = UserDefaults.standard.double(forKey: "engineIdleSeconds")
        return v == 0 ? 35 : v
    }"""),
])

# --- 3 ter. place disque ----------------------------------------------------
patch("ModelStore.swift", [
    ("""        let free = (try? Setup.modelsFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max""",
     """        #if canImport(Darwin)
        let free = (try? Setup.modelsFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        #else
        // volumeAvailableCapacityForImportantUsage est macOS-only ;
        // statvfs donne les octets libres du systeme de fichiers.
        var st = statvfs()
        let free: Int64 = statvfs(Setup.modelsFolder.path, &st) == 0
            ? Int64(st.f_bavail) * Int64(st.f_frsize) : Int64.max
        #endif"""),
    ("import Foundation\n",
     "import Foundation\n#if canImport(Glibc)\nimport Glibc\n#endif\n"),
])

# --- 5. Combine -------------------------------------------------------------
(SRC / "CombineShim.swift").write_text('''import Foundation

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
''')

# --- 6. Corbeille XDG -------------------------------------------------------
(SRC / "TrashShim.swift").write_text('''import Foundation

// FileManager.trashItem n'existe pas sous Linux : on l'ecrit selon la
// specification XDG (~/.local/share/Trash). Meme intention que sur macOS :
// l'enregistrement va a la corbeille, rien n'est efface definitivement.
#if !canImport(Darwin)
extension FileManager {
    func trashItem(at url: URL, resultingItemURL: UnsafeMutablePointer<URL?>?) throws {
        let base = homeDirectoryForCurrentUser.appendingPathComponent(".local/share/Trash", isDirectory: true)
        let files = base.appendingPathComponent("files", isDirectory: true)
        let info = base.appendingPathComponent("info", isDirectory: true)
        try? createDirectory(at: files, withIntermediateDirectories: true)
        try? createDirectory(at: info, withIntermediateDirectories: true)

        var name = url.lastPathComponent
        var n = 1
        while fileExists(atPath: files.appendingPathComponent(name).path) {
            n += 1
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            name = ext.isEmpty ? "\\(stem).\\(n)" : "\\(stem).\\(n).\\(ext)"
        }
        let destination = files.appendingPathComponent(name)
        try moveItem(at: url, to: destination)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = "[Trash Info]\\nPath=\\(url.path)\\nDeletionDate=\\(stamp)\\n"
        try? body.write(to: info.appendingPathComponent("\\(name).trashinfo"),
                        atomically: true, encoding: .utf8)
        resultingItemURL?.pointee = destination
    }
}
#endif
''')

# --- le port du moteur, reglable (8090 est souvent pris sous Linux) --------
patch("ModelCatalog.swift", [
    ("    let port: Int", "    var port: Int"),
    ("    static let all: [ModelInfo] = [",
     """    /// Port impose par PLUME_PORT : sous Linux, 8090 est souvent deja pris
    /// (crowdsec, un autre service...). Sans surcharge, on garde les ports du
    /// catalogue macOS, pour que la configuration reste la meme partout.
    static var portOverride: Int? = nil

    private static let base: [ModelInfo] = ["""),
])

_p = SRC / "ModelCatalog.swift"
_s = _p.read_text()
if "static let all: [ModelInfo]" not in _s:
    # fermer la liste brute et exposer `all` qui applique la surcharge
    idx = _s.index("    private static let base: [ModelInfo] = [")
    end = _s.index("\n    ]\n", idx) + len("\n    ]\n")
    _s = (_s[:end]
          + """
    /// Le catalogue, avec le port eventuellement surcharge par PLUME_PORT.
    static let all: [ModelInfo] = base.map { m in
        guard let p = portOverride, m.family != .cloud else { return m }
        var copy = m
        copy.port = p
        return copy
    }
"""
          + _s[end:])
    _p.write_text(_s)
    print("ModelCatalog.swift : surcharge de port")

# --- 5 bis. les deux enums vivent dans Prefs.swift (SwiftUI) : recopies -----
for name, first, last in [("DictationLanguage.swift", 6, 45),
                          ("PromptLanguage.swift", 144, 166)]:
    prefs = ORIG / "Prefs.swift"
    if not prefs.exists():
        print(f"  ! {name} : Prefs.swift introuvable")
        continue
    lines = prefs.read_text().splitlines(keepends=True)
    body = "".join(lines[first - 1:last])
    header = ("import Foundation\n\n"
              "// Recopie de Prefs.swift (fichier SwiftUI), a l'identique : la couche\n"
              "// logique en a besoin et ne doit pas dependre de l'interface.\n\n")
    (SRC / name).write_text(header + body)

# --- les deux usages de Prefs dans la logique ------------------------------
patch("History.swift", [
    ("d.text = Leet.transform(d.raw, level: Prefs.shared.leetLevel)",
     """// La couche logique ne depend pas de Prefs (fichier SwiftUI) : on lit la
            // meme cle, avec le meme defaut.
            let level = Leet.Level(rawValue: UserDefaults.standard.string(forKey: "leetLevel") ?? "") ?? .medium
            d.text = Leet.transform(d.raw, level: level)"""),
])

print(f"portage applique : {stats['ok']} retouche(s), {stats['miss']} motif(s) manquant(s)")
if stats["miss"]:
    sys.exit(1)
