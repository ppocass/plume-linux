import Foundation

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
            name = ext.isEmpty ? "\(stem).\(n)" : "\(stem).\(n).\(ext)"
        }
        let destination = files.appendingPathComponent(name)
        try moveItem(at: url, to: destination)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = "[Trash Info]\nPath=\(url.path)\nDeletionDate=\(stamp)\n"
        try? body.write(to: info.appendingPathComponent("\(name).trashinfo"),
                        atomically: true, encoding: .utf8)
        resultingItemURL?.pointee = destination
    }
}
#endif
