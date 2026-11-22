import Foundation
import Testing
@testable import PVEKit

@Suite("JSON decoding")
struct DecodingTests {
    @Test func clusterResources() throws {
        let resources = try Fixture.decode([ClusterResource].self, "cluster_resources")
        #expect(resources.count == 11)

        let node = try #require(resources.first { $0.id == "node/pve1" })
        #expect(node.kind == .node)
        #expect(node.isOnline)
        #expect(node.maxcpu == 16)
        #expect(node.uptime == 1_234_567)

        let vm = try #require(resources.first { $0.id == "qemu/100" })
        #expect(vm.kind == .qemu)
        #expect(vm.vmid == 100)
        #expect(vm.isRunning)
        #expect(vm.tags == ["web"])
        #expect(vm.guestRef == GuestRef(node: "pve1", type: .qemu, vmid: 100))
        #expect(abs((vm.memoryFraction ?? 0) - 0.3) < 0.01)

        let template = try #require(resources.first { $0.id == "qemu/9000" })
        #expect(template.template)

        let storage = try #require(resources.first { $0.id == "storage/pve1/local-lvm" })
        #expect(storage.kind == .storage)
        #expect(storage.displayName == "local-lvm")
        #expect(storage.shared == false)

        let network = try #require(resources.first { $0.id == "network/pve1/vmbr0" })
        #expect(network.kind == .other("network"))

        let win = try #require(resources.first { $0.id == "qemu/101" })
        #expect(win.tags == ["desktop", "windows"])
    }

    @Test func groupingByNode() throws {
        let groups = NodeGroup.group(try Fixture.decode([ClusterResource].self, "cluster_resources"))
        #expect(groups.map(\.node) == ["pve1", "pve2"])
        let pve1 = groups[0]
        #expect(pve1.nodeResource?.id == "node/pve1")
        #expect(pve1.guests.map(\.vmid) == [100, 101, 200])
        #expect(pve1.storages.map(\.displayName) == ["local", "local-lvm"])
        #expect(groups[1].guests.map(\.vmid) == [9000])
        #expect(groups[1].nodeResource?.isOnline == false)
    }

    @Test func guestStatus() throws {
        let qemu = try Fixture.decode(GuestStatus.self, "guest_status_qemu")
        #expect(qemu.isRunning)
        #expect(!qemu.isPaused)
        #expect(qemu.agent)
        #expect(qemu.haState == "started")
        #expect(qemu.cpus == 2)

        let paused = try Fixture.decode(GuestStatus.self, "guest_status_qemu_paused")
        #expect(paused.isPaused)
        #expect(paused.effectiveState == "paused")

        let lxc = try Fixture.decode(GuestStatus.self, "guest_status_lxc")
        #expect(lxc.vmid == 200) // string in fixture
        #expect(lxc.maxswap == 536_870_912)
        #expect(lxc.haState == nil)
    }

    @Test func guestConfig() throws {
        let config = try Fixture.decode(GuestConfig.self, "guest_config_qemu")
        #expect(config["digest"] == nil)
        #expect(config["memory"] == "4096")
        #expect(config["cores"] == "2")
        #expect(config["onboot"] == "1")
        let keys = config.entries.map(\.key)
        #expect(keys.first == "name")
        // Natural ordering for device keys.
        let scsi = keys.filter { $0.hasPrefix("scsi") && $0 != "scsihw" }
        #expect(scsi == ["scsi0", "scsi2", "scsi10"])
    }

    @Test func nodeStatus() throws {
        let status = try Fixture.decode(NodeStatus.self, "node_status")
        #expect(status.loadavg == ["0.42", "0.38", "0.35"])
        #expect(status.cpuinfo?.cpus == 32)
        #expect(abs((status.memory?.fraction ?? 0) - 0.1994) < 0.001)
        #expect(status.pveversion?.contains("9.2") == true)
    }

    @Test func rrdNodeAndGuest() throws {
        let node = try Fixture.decode([RRDPoint].self, "rrd_node")
        #expect(node.count == 3)
        #expect(node[0].time == Date(timeIntervalSince1970: 1_763_800_000))
        #expect(node.samples(.memoryUsed).count == 2)
        #expect(node.samples(.memoryUsed).first?.value == 13_421_772_800)
        #expect(node.contains(.ioWait))
        #expect(!node.contains(.diskRead))
        #expect(node[2].values.isEmpty) // gap

        let guest = try Fixture.decode([RRDPoint].self, "rrd_guest")
        #expect(guest.samples(.memoryUsed).map(\.value) == [1_288_490_188, 1_300_000_000])
        #expect(guest.samples(.cpu).last?.value == 0.03) // numeric string
        #expect(guest.contains(.diskWrite))
        #expect(!guest.contains(.ioWait))
    }

    @Test func tasks() throws {
        let tasks = try Fixture.decode([TaskSummary].self, "tasks_cluster")
        #expect(tasks.count == 3)
        #expect(tasks[0].isRunning)
        #expect(tasks[1].succeeded)
        #expect(tasks[1].user == "alice@pve!automation")
        #expect(!tasks[2].succeeded)
        #expect(tasks[2].status == "migration aborted")

        let running = try Fixture.decode(TaskStatus.self, "task_status_running")
        #expect(running.isRunning)
        #expect(!running.succeeded)
        let ok = try Fixture.decode(TaskStatus.self, "task_status_ok")
        #expect(ok.succeeded)
        let failed = try Fixture.decode(TaskStatus.self, "task_status_failed")
        #expect(!failed.isRunning)
        #expect(!failed.succeeded)

        let log = try Fixture.decode([TaskLogLine].self, "task_log")
        #expect(log.map(\.n) == [1, 2, 3])
        #expect(log.last?.t == "TASK OK")
    }

    @Test func upidParsing() throws {
        let upid = try #require(UPID("UPID:pve1:000ABCDE:0123ABCD:6921A3F0:qmstart:100:root@pam:"))
        #expect(upid.node == "pve1")
        #expect(upid.pid == 0xABCDE)
        #expect(upid.type == "qmstart")
        #expect(upid.objectID == "100")
        #expect(upid.user == "root@pam")
        #expect(upid.startTime == fixtureTicketDate)

        let token = try #require(UPID("UPID:pve1:000ABCDF:0123ABCD:6921A3F0:vncshell::root@pam!chelate:"))
        #expect(token.objectID == "")
        #expect(token.user == "root@pam!chelate")

        #expect(UPID("not-a-upid") == nil)
        #expect(UPID("UPID:pve1:zz:0:0:x:y:z:") == nil)
        #expect(TaskOutcome.isSuccess("WARNINGS: 2"))
    }

    @Test func snapshots() throws {
        let list = try Fixture.decode([Snapshot].self, "snapshots")
        #expect(list.count == 3)
        #expect(list.first?.isCurrent == true)
        let real = list.realSnapshots
        #expect(real.map(\.name) == ["before-upgrade", "base"])
        #expect(real[0].vmstate)
        #expect(real[0].description == nil) // empty string normalized
        #expect(real[1].description == "fresh install")

        #expect(Snapshot.isValidName("pre_update-1"))
        #expect(!Snapshot.isValidName("1abc"))
        #expect(!Snapshot.isValidName("bad name"))
        #expect(!Snapshot.isValidName("current"))
        #expect(!Snapshot.isValidName("快照"))
        #expect(!Snapshot.isValidName(String(repeating: "a", count: 41)))
    }

    @Test func permissions() throws {
        let map = try Fixture.decode(PermissionMap.self, "permissions")
        #expect(map.allows(.vmPowerMgmt, on: "/vms/100"))
        #expect(map.allows(.vmConsole, on: "/vms/100")) // value 0 = not propagated, still granted
        #expect(!map.allows(.vmSnapshot, on: "/vms/100"))
        // /vms/101 not listed → falls back to /vms
        #expect(map.allows(.vmAudit, on: "/vms/101"))
        #expect(!map.allows(.vmPowerMgmt, on: "/vms/101"))
        #expect(map.allows(.sysConsole, on: "/nodes/pve1"))
        #expect(!map.allows(.sysConsole, on: "/nodes/pve2")) // falls back to "/"
        #expect(map.allows(.sysAudit, on: "/nodes/pve2"))
    }

    @Test func proxyTickets() throws {
        let term = try Fixture.decode(ProxyTicket.self, "termproxy")
        #expect(term.user == "root@pam!chelate")
        #expect(term.port == 5900)
        let vnc = try Fixture.decode(ProxyTicket.self, "vncproxy")
        #expect(vnc.port == 5901) // string port
        #expect(vnc.ticket.hasPrefix("PVEVNC:"))
    }

    @Test func errorEnvelopes() throws {
        let param = try Fixture.data("error_param")
        #expect(throws: PVEError.http(status: 400, message: "Parameter verification failed. — snapname: invalid format - invalid configuration ID 'bad name'")) {
            _ = try ResponseDecoding.decode(String.self, data: param, response: Fixture.response(400))
        }
        let forbidden = try Fixture.data("error_forbidden")
        #expect(throws: PVEError.forbidden(message: "Permission check failed (/vms/100, VM.PowerMgmt)")) {
            _ = try ResponseDecoding.decode(String.self, data: forbidden, response: Fixture.response(403))
        }
        #expect(throws: PVEError.unauthorized(message: nil)) {
            _ = try ResponseDecoding.decode(String.self, data: Data(), response: Fixture.response(401))
        }
        #expect(throws: PVEError.http(status: 596, message: nil)) {
            _ = try ResponseDecoding.decode(String.self, data: Data("<html>".utf8), response: Fixture.response(596))
        }
    }

    @Test func jsonValueDisplay() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":1,"b":[true,"x"],"c":1.5}"#.utf8))
        #expect(value.displayString == "a=1,b=1, x,c=1.5")
    }
}
