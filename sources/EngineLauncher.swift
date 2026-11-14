import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Le moteur, lance par `plume` lui-meme.
//
// Sur macOS, c'est SpeechEngine qui lance le serveur du modele choisi, avec
// les ports du catalogue (8090, 8195, 8196…) et le reglage « garder le moteur
// charge N secondes » (Prefs.idleSeconds, 35 s par defaut). Ce fichier fait la
// meme chose sous Linux, sans passer par SpeechEngine : `plume models use`
// change de modele et de port, et le service systemd ne peut pas suivre.
//
// La regle de SpeechEngine est reprise telle quelle : **s'attacher ou
// lancer**. Si le port repond, on s'en sert et on n'y touche jamais ; sinon on
// lance, et on n'arrete que ce qu'on a lance.

enum EngineLauncher {

    /// Le binaire whisper-server, tel que configure (local.json) ou installe.
    static var binary: String? {
        if let p = LocalConfig.current?.whisper?.binary.map(LocalConfig.expand),
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/whisper-server",
            "/usr/local/bin/whisper-server",
            "/usr/bin/whisper-server",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Le modele sur disque pour ce modele du catalogue.
    static func modelFile(_ m: ModelInfo) -> String? {
        // Whisper : un seul fichier .bin dans le dossier du modele.
        let folder = ModelLocation.plumeFolder(m)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return nil
        }
        for name in files where name.hasSuffix(".bin") {
            return folder.appendingPathComponent(name).path
        }
        return nil
    }

    /// Le port repond-il, et est-ce bien whisper-server ?
    ///
    /// Piege mesure : un `GET /` sur un port occupe par AUTRE chose (ici un
    /// service Docker sur 8090) rend 404, et un test « code == 200 » conclut
    /// a tort que le moteur est pret — puis la transcription echoue en 404 sur
    /// /inference. On verifie donc que la reponse contient « Whisper », la
    /// page que whisper-server sert sur GET /.
    static func isUp(port: Int) -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data, let body = String(data: data, encoding: .utf8),
               body.contains("Whisper") {
                ok = true
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 2)
        return ok
    }

    /// Un port libre, a partir de celui du catalogue. Sous Linux, les ports du
    /// catalogue Plume sont parfois deja pris (crowdsec sur 8090, un autre
    /// service sur 8095…). On decale vers le haut jusqu'a trouver un libre.
    static func freePort(startingAt preferred: Int) -> Int {
        for candidate in preferred..<(preferred + 20) {
            if !portBusy(candidate) { return candidate }
            // Occupe par whisper-server lui-meme ? Alors il est a nous.
            if isUp(port: candidate) { return candidate }
        }
        return preferred
    }

    private static func portBusy(_ port: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ss")
        p.arguments = ["-lptnH", "sport = :\(port)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// S'assure que le moteur du modele choisi tourne, et rend son port.
    /// Lance whisper-server au besoin ; rend nil si le moteur n'est pas
    /// installé.
    static func ensureRunning(_ m: ModelInfo) -> Int? {
        let port = freePort(startingAt: m.port)
        if isUp(port: port) { return port }          // deja la : on s'y attache

        guard let binary, let model = modelFile(m) else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-m", model, "--host", "127.0.0.1", "--port", "\(port)", "-t", "4"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        // Le modele met quelques secondes a charger. On attend jusqu'a 90 s.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if isUp(port: port) {
                // On le laisse tourner apres notre depart : il sert la
                // prochaine dictee, comme le moteur « partage » de Plume sur
                // macOS. Un enfant ne meurt pas avec son parent sous Linux.
                return port
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        p.terminate()
        return nil
    }
}
