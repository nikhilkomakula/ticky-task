import CoreGraphics
import Foundation

/// A logical container that can hold reorderable rows. **Surface-qualified** so the
/// same day key appearing in the month grid and the month detail agenda never
/// collide when rows are grouped by container.
enum ReorderContainer: Hashable {
    case weekDay(String)     // a week-view day column ("yyyyMMdd")
    case monthDay(String)    // a month-grid / mini-calendar cell (append-only)
    case agendaDay(String)   // a single-day agenda (month detail, menu bar)
    case list(UUID)          // a custom list's task list
    case listsRow            // the horizontal row of custom-list cards (rows are cards)

    var dayKey: String? {
        switch self {
        case .weekDay(let k), .monthDay(let k), .agendaDay(let k): return k
        case .list, .listsRow: return nil
        }
    }

    /// Maps to a persistence `TaskLocation`. Day-kinds → `.day(key)`; `.list` uses
    /// the resolver to fetch the `CustomList`; `.listsRow` holds cards, not tasks.
    func taskLocation(resolveList: (UUID) -> CustomList?) -> TaskLocation? {
        switch self {
        case .weekDay(let k), .monthDay(let k), .agendaDay(let k): return .day(k)
        case .list(let id): return resolveList(id).map { .customList($0) }
        case .listsRow: return nil
        }
    }
}

/// What is being dragged.
enum DragKind: Hashable { case task, listCard }

/// The axis a container lays its rows along.
enum ReorderAxis: Hashable { case vertical, horizontal }

/// A row's frame in the shared "planner" coordinate space.
struct RowSnapshot: Equatable {
    let id: UUID
    let container: ReorderContainer
    let frame: CGRect
}

/// A container's frame and how it accepts drops.
struct ContainerSnapshot: Equatable {
    let container: ReorderContainer
    let frame: CGRect
    let accepts: DragKind
    let axis: ReorderAxis
    let isEmpty: Bool
}

/// The resolved drop: which container, and the id to insert before (nil = append).
struct ReorderTarget: Equatable {
    let container: ReorderContainer
    let beforeID: UUID?
}
