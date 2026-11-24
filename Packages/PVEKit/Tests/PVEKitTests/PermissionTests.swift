import Foundation
import Testing
@testable import PVEKit

@Suite("download-url privilege requirement")
struct PermissionTests {
    let requirement = DownloadURLRequirement(node: "pve", storage: "local")

    func missing(_ map: [String: Set<String>]) -> [DownloadURLRequirement.Missing] {
        let permissions = PermissionMap(paths: map)
        return requirement.missing { permissions.allows($0, on: $1) }
    }

    @Test func allowedWithRootAuditAndModify() {
        #expect(missing([
            "/storage/local": ["Datastore.AllocateTemplate"],
            "/": ["Sys.Audit", "Sys.Modify"],
            "/nodes/pve": [],
        ]).isEmpty)
    }

    @Test func allowedWithNodeAccessNetwork() {
        #expect(missing([
            "/storage/local": ["Datastore.AllocateTemplate"],
            "/": ["Sys.Audit"],
            "/nodes/pve": ["Sys.AccessNetwork"],
        ]).isEmpty)
    }

    @Test func reportsEachMissingPart() {
        let result = missing([
            "/storage/local": [],
            "/": ["Sys.Audit"],
            "/nodes/pve": [],
        ])
        #expect(result == [
            .privilege(.datastoreAllocateTemplate, path: "/storage/local"),
            .networkAccess(rootMissing: [.sysModify], rootPath: "/", nodePath: "/nodes/pve"),
        ])
    }

    @Test func templateIdentityIncludesArchitecture() throws {
        let json = """
        {"data":[{"template":"debian-13-standard_13.1-2.tar.zst","architecture":"amd64"},
         {"template":"debian-13-standard_13.1-2.tar.zst","architecture":"arm64"}]}
        """
        let list = try ResponseDecoding.decode([ApplianceTemplate].self, data: Data(json.utf8), response: Fixture.response(200))
        #expect(Set(list.map(\.id)).count == 2)
    }
}
