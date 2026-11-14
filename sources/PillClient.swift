import Foundation

/// Le pilote de la pastille : un petit processus (plume-pill, GTK4) qu'on lance
/// au debut d'une dictee et a qui on parle par des lignes sur son entree
/// standard.
///
/// Pourquoi un processus separe plutot que GTK dans le binaire principal : le
/// binaire `plume` reste une simple commande, utilisable sans affichage (SSH,
/// `plume text`), et la pastille est une dependance qu'on peut ne pas avoir.
/// Si `plume-pill` est absent, la dictee marche quand meme — elle est
/// seulement muette visuellement.
///
/// C'est le meme decoupage que sur macOS, ou la pastille est un NSPanel separe
/// du controleur de dictee.
final class PillClient {
    private var process: Process?
    private var input: FileHandle?

    /// Le chemin du binaire de la pastille, s'il est installe.
    static var binary: String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/plume-pill",
            "/usr/local/bin/plume-pill",
            "/usr/bin/plume-pill",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // A cote du binaire plume, pour un essai depuis les sources.
        if let exe = Bundle.main.executablePath {
            let sibling = (exe as NSString).deletingLastPathComponent + "/plume-pill"
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        return nil
    }

    /// Sans affichage (SSH sans -X), il n'y a pas de pastille a montrer.
    static var displayAvailable: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["DISPLAY"] != nil || env["WAYLAND_DISPLAY"] != nil
    }

    var isActive: Bool { process?.isRunning == true }

    /// Lance la pastille. Silencieux si elle n'est pas installee ou s'il n'y a
    /// pas d'affichage : la dictee n'en depend pas.
    func start() {
        guard process == nil, Self.displayAvailable, let binary = Self.binary else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return
        }
        process = p
        input = pipe.fileHandleForWriting
        // Une seconde pour que GTK ouvre sa fenetre : sans cela les premiers
        // niveaux partent avant que la pastille n'ecoute.
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func send(_ line: String) {
        guard let input else { return }
        input.write(Data((line + "\n").utf8))
    }

    /// Un niveau du micro (0…1). Appele ~20 fois par seconde.
    func level(_ v: Float) { send(String(format: "level %.3f", v)) }

    func recording()  { send("phase recording") }
    func processing() { send("phase processing") }
    func pasted()     { send("phase pasted") }
    func hide()       { send("hide") }

    /// Laisse la pastille visible le temps qu'on la regarde, puis la ferme.
    func finish(after seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
        send("quit")
        // Fermer le tube : la pastille voit EOF et sort meme si « quit »
        // n'est pas arrive (tube plein, pastille figee).
        try? input?.close()
        input = nil
        if let p = process {
            // Si elle ne repond pas, on ne bloque pas : on la termine.
            let deadline = Date().addingTimeInterval(1.5)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { p.terminate() }
        }
        process = nil
        input = nil
    }
}
