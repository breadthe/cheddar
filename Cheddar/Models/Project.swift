import Foundation

struct Project: Identifiable, Hashable, Codable {
    var id: String { path }

    /// The main repo's working tree.
    var path: String
    /// Per-project trunk override; nil means automatic (origin/HEAD, else main, else master).
    var trunk: String?

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}
