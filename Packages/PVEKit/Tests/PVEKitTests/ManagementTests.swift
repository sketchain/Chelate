import Foundation
import Testing
@testable import PVEKit

@Suite("Backups, restore, clone, migration, hardware")
struct ManagementTests {
    let endpoint = ServerEndpoint(host: "pve.example")

    func client(_ transport: MockTransport) -> PVEClient {
        let auth = AuthSession(mode: .apiToken(APIToken(userID: "root@pam", tokenID: "t", secret: "s")), endpoint: endpoint, transport: transport)
        return PVEClient(endpoint: endpoint, auth: auth, transport: transport)
    }

    func fields(_ parameters: [(String, String)]) -> [String: String] {
        Dictionary(parameters, uniquingKeysWith: { _, last in last })
    }

    @Test func nodeStorageFormats() throws {
        let storages = try Fixture.decode([NodeStorage].self, "node_storage")
        #expect(storages.map(\.storage) == ["local", "local-zfs", "pbs"])
        let local = storages[0]
        #expect(local.supportedFormats == [.raw, .qcow2, .vmdk])
        #expect(local.preferredFormat == .qcow2)
        #expect(local.offersFormatChoice)
        #expect(local.formatChoices == [.raw, .qcow2, .vmdk])
        let zfs = storages[1]
        #expect(zfs.supportedFormats == [.raw])
        #expect(zfs.preferredFormat == .raw)
        #expect(!zfs.offersFormatChoice)
        #expect(zfs.supports("rootdir"))
        #expect(storages[2].isPBS)
        #expect(storages[2].active)
        #expect(storages[2].shared)
    }

    @Test func backupVolumes() throws {
        let items = try Fixture.decode([StorageContentItem].self, "backup_content")
        let backups = items.map { BackupVolume(storage: "local", item: $0) }.newestFirst
        #expect(backups.count == 2)
        #expect(backups[0].volid.hasSuffix("2026_11_21-03_00_02.vma.zst"))
        #expect(backups[0].guestType == .qemu)
        #expect(backups[1].isProtected)
        #expect(!backups[0].isPBS)

        let pbs = BackupVolume(storage: "pbs", item: StorageContentItem(volid: "pbs:backup/ct/200/2026-11-20T03:00:02Z", content: "backup", format: "pbs-ct"))
        #expect(pbs.vmid == 200)
        #expect(pbs.isPBS)
        #expect(pbs.guestType == .lxc)
        #expect(pbs.ctime == ISO8601DateFormatter().date(from: "2026-11-20T03:00:02Z"))
        #expect(BackupVolume.vmid(fromVolid: "local:backup/vzdump-lxc-201-2026_01_02-03_04_05.tar.zst") == 201)
    }

    @Test func backupModeFromLog() {
        let log = [
            "INFO: starting new backup job: vzdump 100 101 --mode snapshot --storage local",
            "INFO: Starting Backup of VM 100 (qemu)",
            "INFO: backup mode: snapshot",
            "INFO: Starting Backup of VM 101 (qemu)",
            "INFO: backup mode: stop",
        ]
        #expect(BackupMode.fromTaskLog(log, vmid: 101) == .stop)
        #expect(BackupMode.fromTaskLog(log, vmid: 100) == .snapshot)
        #expect(BackupMode.fromTaskLog(["INFO: backup mode: suspend"]) == .suspend)
        #expect(BackupMode.fromTaskLog(["nothing"]) == nil)
    }

    @Test func notesTemplateEscaping() {
        #expect(NotesTemplate.escape("{{guestname}}\nnightly \\ ok") == "{{guestname}}\\nnightly \\\\ ok")
        #expect(NotesTemplate.unescape("a\\nb\\\\c") == "a\nb\\c")
        #expect(NotesTemplate.unescape(NotesTemplate.escape("x\\n\ny")) == "x\\n\ny")
    }

    @Test func backupRequestMatchesWebUI() {
        var backup = BackupRequest(vmid: 100, storage: "local")
        backup.notes = "{{guestname}}\nmanual"
        let request = fields(backup.request(node: "pve").parameters)
        #expect(request["storage"] == "local")
        #expect(request["vmid"] == "100")
        #expect(request["mode"] == "snapshot")
        #expect(request["remove"] == "0")
        #expect(request["compress"] == "zstd")
        #expect(request["notification-mode"] == "notification-system")
        #expect(request["notes-template"] == "{{guestname}}\\nmanual")
        #expect(request["protected"] == nil)
        #expect(request["mailto"] == nil)

        var pbs = BackupRequest(vmid: 200, storage: "pbs")
        pbs.storageIsPBS = true
        pbs.guestType = .lxc
        pbs.compression = .none
        pbs.changeDetection = .metadata
        pbs.isProtected = true
        pbs.prune = true
        pbs.notificationMode = .legacySendmail
        pbs.mailto = "admin@example.com"
        let pbsFields = fields(pbs.request(node: "pve").parameters)
        #expect(pbsFields["compress"] == "zstd")
        #expect(pbsFields["pbs-change-detection-mode"] == "metadata")
        #expect(pbsFields["protected"] == "1")
        #expect(pbsFields["remove"] == "1")
        #expect(pbsFields["mailto"] == "admin@example.com")
    }

    @Test func retention() throws {
        let retention = try #require(BackupRetention("keep-daily=7,keep-last=3,keep-weekly=4"))
        #expect(retention.offersPrune)
        #expect(retention.keeps.map(\.name) == ["keep-last", "keep-daily", "keep-weekly"])
        #expect(BackupRetention("keep-all=1")?.offersPrune == false)
        #expect(BackupRetention(nil) == nil)
    }

    @Test func extractConfig() {
        let summary = BackupConfigSummary(config: """
        #qmdump#map:scsi0:drive-scsi0:local-zfs:raw:
        #qmdump#map:scsi1:drive-scsi1::raw:
        cores: 4
        memory: 8192
        name: debian-web
        meta: creation-qemu=10.1.2,ctime=1763000000,uid=abc123
        sockets: 1
        """)
        #expect(summary.name == "debian-web")
        #expect(summary.cores == "4")
        #expect(summary.memory == "8192")
        #expect(summary.uid == "abc123")
        #expect(summary.mappedStorages == ["local-zfs", nil])
    }

    @Test func restoreRequests() {
        var vm = RestoreRequest(volid: "local:backup/vzdump-qemu-100-x.vma.zst", type: .qemu, target: .new(vmid: 105))
        vm.unique = true
        vm.start = true
        vm.name = "restored"
        vm.memory = 2048
        vm.bandwidthLimit = 0
        let vmFields = fields(vm.qemuRequest(node: "pve").parameters)
        #expect(vmFields["vmid"] == "105")
        #expect(vmFields["archive"] == "local:backup/vzdump-qemu-100-x.vma.zst")
        #expect(vmFields["force"] == "0")
        #expect(vmFields["unique"] == "1")
        #expect(vmFields["start"] == "1")
        #expect(vmFields["name"] == "restored")
        #expect(vmFields["memory"] == "2048")
        #expect(vmFields["bwlimit"] == "0")
        #expect(vmFields["storage"] == nil)

        var live = vm
        live.liveRestore = true
        #expect(fields(live.qemuRequest(node: "pve").parameters)["start"] == nil)

        var ct = RestoreRequest(volid: "local:backup/vzdump-lxc-200-x.tar.zst", type: .lxc, target: .overwrite(vmid: 200))
        ct.storage = "local-zfs"
        ct.name = "pihole"
        ct.privilegeLevel = .privileged
        ct.allowIdentityMismatch = true
        let ctFields = fields(ct.lxcRequest(node: "pve").parameters)
        #expect(ctFields["ostemplate"] == "local:backup/vzdump-lxc-200-x.tar.zst")
        #expect(ctFields["restore"] == "1")
        #expect(ctFields["force"] == "1")
        #expect(ctFields["hostname"] == "pihole")
        #expect(ctFields["unprivileged"] == "0")
        #expect(ctFields["storage"] == "local-zfs")
        #expect(ctFields["allow-identity-mismatch"] == "1")
    }

    @Test func cloneRequests() {
        let template = GuestRef(node: "pve", type: .qemu, vmid: 9000)
        var linked = CloneRequest(source: template, newid: 110, isTemplate: true)
        linked.name = "web-2"
        linked.storage = "local"
        let linkedFields = fields(linked.qemuRequest().parameters)
        #expect(linked.mode == .linked)
        #expect(linkedFields["newid"] == "110")
        #expect(linkedFields["full"] == nil)
        #expect(linkedFields["storage"] == nil, "linked clones keep the template's storage")

        var full = CloneRequest(source: GuestRef(node: "pve", type: .qemu, vmid: 100), newid: 111, isTemplate: false)
        full.storage = "local"
        full.format = .qcow2
        full.target = "pve2"
        full.snapshot = "current"
        let fullFields = fields(full.qemuRequest().parameters)
        #expect(fullFields["full"] == "1")
        #expect(fullFields["storage"] == "local")
        #expect(fullFields["format"] == "qcow2")
        #expect(fullFields["target"] == "pve2")
        #expect(fullFields["snapname"] == nil)

        var ct = CloneRequest(source: GuestRef(node: "pve", type: .lxc, vmid: 200), newid: 210, isTemplate: false)
        ct.name = "pihole-2"
        ct.snapshot = "before-upgrade"
        let ctFields = fields(ct.lxcRequest().parameters)
        #expect(ctFields["hostname"] == "pihole-2")
        #expect(ctFields["snapname"] == "before-upgrade")
        #expect(ctFields["full"] == "1")
    }

    @Test func migration() throws {
        let output = try Fixture.decode(PVEAPI.GetNodesQemuMigrate.Output.self, "migrate_qemu")
        let check = MigrationCheck(output)
        #expect(!check.running)
        #expect(check.hasLocalDisks)
        #expect(check.unavailableStorages["pve2"] == ["local-zfs"])
        let toPVE2 = check.messages(target: "pve2", vmid: 100, force: false)
        #expect(toPVE2.contains { $0.severity == .error && $0.text.contains("local-zfs") })
        #expect(toPVE2.contains { $0.severity == .error && $0.text.contains("hostpci0") })
        #expect(!check.allowsMigration(target: "pve3", vmid: 100, force: false))
        #expect(check.allowsMigration(target: "pve3", vmid: 100, force: true))

        let guest = GuestRef(node: "pve", type: .qemu, vmid: 100)
        var online = MigrateRequest(guest: guest, target: "pve2", running: true, withLocalDisks: true)
        online.targetStorage = "local-lvm"
        let onlineFields = fields(online.qemuRequest().parameters)
        #expect(onlineFields["online"] == "1")
        #expect(onlineFields["with-local-disks"] == "1")
        #expect(onlineFields["targetstorage"] == "local-lvm")

        var ct = MigrateRequest(guest: GuestRef(node: "pve", type: .lxc, vmid: 200), target: "pve2", running: true)
        ct.restartTimeout = 60
        let ctFields = fields(ct.lxcRequest().parameters)
        #expect(ctFields["restart"] == "1")
        #expect(ctFields["timeout"] == "60")
    }

    @Test func destroy() {
        var destroy = DestroyGuestRequest(guest: GuestRef(node: "pve", type: .lxc, vmid: 201))
        #expect(destroy.confirms(" 201 "))
        #expect(!destroy.confirms("20"))
        destroy.purge = true
        let request = destroy.lxcRequest()
        #expect(request.path == "/nodes/pve/lxc/201")
        #expect(fields(request.parameters)["purge"] == "1")
        #expect(fields(request.parameters)["destroy-unreferenced-disks"] == "0")
    }

    @Test func pendingHardware() throws {
        let pending = try Fixture.decode([PendingEntry].self, "pending_qemu")
        let hardware = GuestHardware(type: .qemu, pending: pending)
        #expect(hardware.current("cores") == 2)
        #expect(hardware.cores == 4)
        #expect(hardware.isPending("cores"))
        #expect(!hardware.isPending("sockets"))
        #expect(hardware.memory == 4096)
        #expect(hardware.balloon == 2048)
        #expect(hardware.isPending("onboot"))
        #expect(hardware.disks.map(\.key) == ["scsi0", "virtio1"], "no CD-ROM, no EFI disk")
        let disk = try #require(hardware.disks.first)
        #expect(disk.size == 32.0 * 1_073_741_824.0)
        #expect(disk.storage == "local-zfs")

        let ct = GuestHardware(type: .lxc, pending: [
            PendingEntry(key: "rootfs", value: "local-zfs:subvol-200-disk-0,size=8G"),
            PendingEntry(key: "mp0", value: "local-zfs:subvol-200-disk-1,mp=/data,size=100G"),
            PendingEntry(key: "memory", value: "512"),
        ])
        #expect(ct.disks.map(\.key) == ["rootfs", "mp0"])
        #expect(ct.swap == 512)
    }

    @Test func diskResize() throws {
        let disk = GuestDisk(key: "scsi0", config: "local-zfs:vm-100-disk-0,size=32G")
        let grow = DiskResize(disk: disk, input: .increment(gib: 8))
        #expect(grow.newSize == 40.0 * 1_073_741_824.0)
        #expect(grow.sizeParameter == "+8G")
        let target = DiskResize(disk: disk, input: .target(gib: 50.5))
        #expect(target.sizeParameter == "50.5G")
        #expect(!DiskResize(disk: disk, input: .target(gib: 16)).isValid, "shrinking is not possible")
        #expect(!DiskResize(disk: disk, input: .increment(gib: 0)).isValid)
        let request = try #require(grow.qemuRequest(GuestRef(node: "pve", type: .qemu, vmid: 100)))
        #expect(fields(request.parameters) == ["disk": "scsi0", "size": "+8G"])
        #expect(DiskSize.bytes("1.5T") == 1.5 * 1_099_511_627_776)
        #expect(DiskSize.bytes("754M") == 754.0 * 1_048_576.0)
    }

    @Test func hardwareChange() {
        let guest = GuestRef(node: "pve", type: .qemu, vmid: 100)
        let change = HardwareChange(cores: 4, sockets: 2, memory: 8192, balloon: 2048)
        #expect(change.isValid)
        let request = fields(change.qemuRequest(guest).parameters)
        #expect(request["cores"] == "4")
        #expect(request["sockets"] == "2")
        #expect(request["memory"] == "8192")
        #expect(request["balloon"] == "2048")
        #expect(!HardwareChange(memory: 1024, balloon: 2048).isValid)
        let ct = fields(HardwareChange(cores: 2, memory: 1024, swap: 256).lxcRequest(GuestRef(node: "pve", type: .lxc, vmid: 200)).parameters)
        #expect(ct == ["cores": "2", "memory": "1024", "swap": "256"])
    }

    @Test func clientRequests() async throws {
        let transport = MockTransport()
        let client = client(transport)
        transport.enqueue(status: 200, body: #"{"data":"106"}"#)
        #expect(try await client.nextVMID() == 106)
        transport.enqueue(status: 400, body: #"{"data":null,"errors":{"vmid":"VM 100 already exists"}}"#)
        #expect(try await client.isVMIDFree(100) == false)
        transport.enqueue(status: 200, body: #"{"data":"101"}"#)
        #expect(try await client.isVMIDFree(101))
        #expect(transport.recorded.last?.url?.query == "vmid=101")

        transport.enqueue(status: 200, body: #"{"data":"UPID:pve:00001:00002:6921A3F0:vzdump:100:root@pam!t:"}"#)
        let upid = try await client.backup(node: "pve", BackupRequest(vmid: 100, storage: "local"))
        #expect(UPID(upid)?.type == "vzdump")
        #expect(transport.recorded.last?.httpMethod == "POST")
        #expect(transport.recorded.last?.url?.path == "/api2/json/nodes/pve/vzdump")

        transport.enqueue(status: 200, body: #"{"data":null}"#)
        let deleted = try await client.deleteVolume(node: "pve", storage: "local", volid: "local:backup/x.vma.zst")
        #expect(deleted == nil)
        #expect(transport.recorded.last?.httpMethod == "DELETE")

        try transport.enqueue("node_storage")
        try transport.enqueue("backup_content")
        try transport.enqueue("backup_content")
        let backups = try await client.backups(node: "pve", vmid: 100)
        #expect(backups.count == 4)
        #expect(backups.first?.ctime == Date(timeIntervalSince1970: 1_763_694_002))
    }
}

@Suite("System log, updates, datacenter, firewall")
struct NodeAndDatacenterTests {
    @Test func structuredJournal() throws {
        let value = try Fixture.decode(JSONValue.self, "journal_structured")
        let page = JournalPage(value, timeZone: TimeZone(identifier: "UTC")!)
        #expect(page.oldestCursor == "s=old;i=1")
        #expect(page.newestCursor == "s=new;i=9")
        #expect(page.entries.count == 3)
        #expect(page.entries[0].text == "Nov 24 16:00:00 pve systemd[1]: Started pveproxy.service.")
        #expect(page.entries[1].isReboot)
        #expect(page.entries[2].priority == 3)
        #expect(page.entries[2].text.contains("line one\n"))
        #expect(page.entries.matching("PVEPROXY").count == 1)
        #expect(page.entries.matching("").count == 3)
    }

    @Test func legacyJournal() throws {
        let page = JournalPage(try Fixture.decode(JSONValue.self, "journal_legacy"))
        #expect(page.oldestCursor == "s=old;i=1")
        #expect(page.newestCursor == "s=new;i=9")
        #expect(page.entries.map(\.text).last == "Nov 24 16:02:00 pve kernel: oops")
    }

    @Test func journalQueries() {
        func query(_ q: JournalQuery) -> [String: String] {
            Dictionary(q.request(node: "pve").parameters, uniquingKeysWith: { _, b in b })
        }
        #expect(query(.latest(count: 500)) == ["lastentries": "500", "structured": "1"])
        #expect(query(.older(than: "c1", count: 500)) == ["lastentries": "500", "endcursor": "c1", "structured": "1"])
        #expect(query(.newer(than: "c9")) == ["startcursor": "c9", "structured": "1"])
        let range = query(.range(since: Date(timeIntervalSince1970: 100), until: Date(timeIntervalSince1970: 200)))
        #expect(range["since"] == "100" && range["until"] == "200")
    }

    @Test func aptPackages() throws {
        let packages = try Fixture.decode([AptPackage].self, "apt_update").sortedForDisplay
        #expect(packages.map(\.name) == ["proxmox-kernel-7.0.15-1-pve-signed", "zfsutils-linux", "curl"])
        #expect(packages[1].versionChange == "2.3.4-pve1 → 2.3.5-pve1")
        #expect(packages[0].versionChange == "7.0.15-1")
    }

    @Test func clusterAndHA() throws {
        let status = ClusterStatus(try Fixture.decode(JSONValue.self, "cluster_status"))
        #expect(status.clusterName == "homelab")
        #expect(status.quorate == true)
        #expect(status.nodes.map(\.name) == ["pve", "pve2"])
        #expect(status.onlineNodes == ["pve"])
        #expect(ClusterStatus(.array([])).isCluster == false)

        let ha = try Fixture.decode([HAStatusEntry].self, "ha_status")
        #expect(ha.first?.quorate == true)
        let resources = HAResource.merge(try Fixture.decode([HAResource].self, "ha_resources"), status: ha)
        #expect(resources.map(\.sid) == ["ct:200", "vm:100"])
        #expect(resources[1].currentState == "started")
        #expect(resources[1].node == "pve")
        #expect(resources[0].currentState == nil)
        #expect(resources[0].comment == "dns")
    }

    @Test func replication() throws {
        let jobs = try Fixture.decode([ReplicationJob].self, "replication_cluster")
        let statuses = Dictionary(uniqueKeysWithValues: try Fixture.decode([ReplicationJob].self, "replication_node").map { ($0.id, $0) })
        let merged = jobs.map { $0.merging(status: statuses[$0.id]) }
        #expect(merged[0].lastSync == Date(timeIntervalSince1970: 1_764_000_000))
        #expect(merged[0].duration == 4.21)
        #expect(merged[0].isHealthy)
        #expect(merged[1].disabled)
        #expect(merged[1].lastSync == nil)
        #expect(merged[1].failCount == 3)
        #expect(!merged[1].isHealthy)
    }

    @Test func firewall() throws {
        let rules = try Fixture.decode([FirewallRule].self, "firewall_rules").sorted { $0.pos < $1.pos }
        #expect(rules.map(\.pos) == [0, 1, 2])
        #expect(rules[0].protocolText == "Web")
        #expect(rules[1].portText == "22")
        #expect(rules[1].source == "10.0.0.0/24")
        #expect(rules[2].type == "group")
        #expect(!rules[2].enabled)
        #expect(try JSONDecoder().decode(FirewallOptions.self, from: Data(#"{"enable":1,"policy_in":"DROP"}"#.utf8)).enabled)
        let request = PVEAPI.PutClusterFirewallOptions()
        #expect(request.path == "/cluster/firewall/options")
        #expect(FirewallScope.guest(GuestRef(node: "pve", type: .lxc, vmid: 200)).modifyPrivilege == .vmConfigNetwork)
    }

    @Test func permissionNeeds() {
        let needs = [PermissionNeed(.vmBackup, on: PermissionNeed.vm(100)), PermissionNeed(.datastoreAllocateSpace, on: "/storage/local"), PermissionNeed(.vmBackup, on: "/vms/100")]
        let missing = needs.missing { privilege, _ in privilege == .datastoreAllocateSpace }
        #expect(missing == [PermissionNeed(.vmBackup, on: "/vms/100")])
    }

    @Test func upgradeConsole() {
        #expect(ConsoleTarget.nodeUpgrade(node: "pve").aclPath == "/nodes/pve")
        #expect(ConsoleTarget.nodeUpgrade(node: "pve").requiredPrivilege == .sysConsole)
    }
}
