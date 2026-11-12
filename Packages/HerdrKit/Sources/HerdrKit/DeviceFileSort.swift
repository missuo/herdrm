import Foundation

#if os(macOS)
public struct DeviceFileSort: Equatable, Sendable {
    public enum Column: String, Sendable {
        case name
        case size
        case modified
    }

    public private(set) var column: Column = .name
    public private(set) var ascending = true

    public init() {}

    public mutating func select(_ column: Column) {
        if self.column == column {
            ascending.toggle()
        } else {
            self.column = column
            ascending = column == .name
        }
    }

    public func sorted(_ entries: [DeviceFileEntry]) -> [DeviceFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.kind == .directory, rhs.kind != .directory { return true }
            if lhs.kind != .directory, rhs.kind == .directory { return false }

            switch column {
            case .name:
                break
            case .size:
                if lhs.size != rhs.size {
                    guard let left = lhs.size else { return false }
                    guard let right = rhs.size else { return true }
                    return ascending ? left < right : left > right
                }
            case .modified:
                if lhs.modificationDate != rhs.modificationDate {
                    guard let left = lhs.modificationDate else { return false }
                    guard let right = rhs.modificationDate else { return true }
                    return ascending ? left < right : left > right
                }
            }

            let byName = lhs.name.localizedStandardCompare(rhs.name)
            return column == .name && !ascending
                ? byName == .orderedDescending
                : byName == .orderedAscending
        }
    }
}
#endif
