import SwiftUI

/// A task or custom list being dragged, for reordering and cross-container moves
/// (a task can move across days and lists). Transfers as a compact `"kind:uuid"`
/// string so no custom UTType / Info.plist declaration is needed.
struct DraggedItem: Transferable {
    enum Kind: String {
        case task
        case list
    }

    let id: UUID
    let kind: Kind

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(
            exporting: { "\($0.kind.rawValue):\($0.id.uuidString)" },
            importing: { string in
                let parts = string.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      let kind = Kind(rawValue: String(parts[0])),
                      let id = UUID(uuidString: String(parts[1])) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return DraggedItem(id: id, kind: kind)
            }
        )
    }
}
