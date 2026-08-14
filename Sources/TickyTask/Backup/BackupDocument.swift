import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// TickyTask's own backup type — a JSON subtype so the file is
    /// distinguishable in the picker but still openable as plain JSON. A
    /// matching exported-type declaration lives in Info.plist.
    static let tickyTaskBackup = UTType(exportedAs: "com.tickytask.backup", conformingTo: .json)
}

/// Thin `FileDocument` used only to hand pre-encoded bytes to `.fileExporter`,
/// which performs the coordinated, atomic document write for us. Import reads
/// the picked URL directly (see `BackupCoordinator`), so this stays write-only
/// in practice.
struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.tickyTaskBackup, .json]
    static let writableContentTypes: [UTType] = [.tickyTaskBackup]

    var data: Data

    init(data: Data = Data()) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw BackupError.corruptPayload }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
