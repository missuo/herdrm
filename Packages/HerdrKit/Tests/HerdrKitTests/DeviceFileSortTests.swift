import Foundation
import Testing
@testable import HerdrKit

struct DeviceFileSortTests {
    private let entries = [
        DeviceFileEntry(name: "file10", path: "/file10", kind: .regularFile,
                        size: 10, modificationDate: Date(timeIntervalSince1970: 200)),
        DeviceFileEntry(name: "Folder", path: "/Folder", kind: .directory),
        DeviceFileEntry(name: "file2", path: "/file2", kind: .regularFile,
                        size: 20, modificationDate: Date(timeIntervalSince1970: 100)),
        DeviceFileEntry(name: "link", path: "/link", kind: .symbolicLink),
    ]

    @Test func columnClicksToggleDirectionAndKeepFoldersFirst() {
        var sort = DeviceFileSort()
        #expect(sort.sorted(entries).map(\.name) == ["Folder", "file2", "file10", "link"])
        sort.select(.name)
        #expect(sort.sorted(entries).map(\.name) == ["Folder", "link", "file10", "file2"])
        sort.select(.modified)
        #expect(!sort.ascending)
        #expect(sort.sorted(entries).map(\.name) == ["Folder", "file10", "file2", "link"])
        sort.select(.modified)
        #expect(sort.ascending)
        #expect(sort.sorted(entries).map(\.name) == ["Folder", "file2", "file10", "link"])
        sort.select(.size)
        #expect(!sort.ascending)
        #expect(sort.sorted(entries).map(\.name) == ["Folder", "file2", "file10", "link"])
        sort.select(.size)
        #expect(sort.sorted(entries).map(\.name) == ["Folder", "file10", "file2", "link"])
    }

    @Test func equalValuesUseNaturalNameOrder() {
        var sort = DeviceFileSort()
        let tied = ["report10", "report2"].map {
            DeviceFileEntry(name: $0, path: "/\($0)", kind: .regularFile,
                            size: 42, modificationDate: Date(timeIntervalSince1970: 100))
        }
        for column in [DeviceFileSort.Column.size, .modified] {
            sort.select(column)
            #expect(sort.sorted(tied).map(\.name) == ["report2", "report10"])
            sort.select(column)
            #expect(sort.sorted(tied).map(\.name) == ["report2", "report10"])
        }
    }

    @Test func independentPaneOrdersApplyToRefreshedEntries() {
        var local = DeviceFileSort()
        var remote = DeviceFileSort()
        local.select(.modified)
        remote.select(.size)
        remote.select(.size)
        let refreshed = entries + [
            DeviceFileEntry(name: "new", path: "/new", kind: .regularFile,
                            size: 15, modificationDate: Date(timeIntervalSince1970: 300))
        ]
        #expect(local.sorted(refreshed).map(\.name) ==
                ["Folder", "new", "file10", "file2", "link"])
        #expect(remote.sorted(refreshed).map(\.name) ==
                ["Folder", "file10", "new", "file2", "link"])
        #expect(!local.ascending)
        #expect(remote.ascending)
    }
}
