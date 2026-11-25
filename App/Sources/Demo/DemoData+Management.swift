import Foundation
import PVEKit

/// Fixtures for backups, restore, clone, migration, hardware, notes, system log, updates,
/// datacenter (HA, replication, firewall) and the create wizards.
extension DemoData {
    /// Second cluster node: online, without guests (migration target, replication target).
    static let secondNode = "pve2"

    static func nodes() -> [[String: Any]] {
        [
            ["node": node, "status": "online", "cpu": 0.046, "maxcpu": 32, "mem": 61 * gib, "maxmem": memTotal, "uptime": 2_548_800, "level": ""],
            ["node": secondNode, "status": "online", "cpu": 0.012, "maxcpu": 8, "mem": 6 * gib, "maxmem": 32 * gib, "uptime": 864_000, "level": ""],
        ]
    }

    static func clusterStatus() -> [[String: Any]] {
        [
            ["type": "cluster", "id": "cluster", "name": "homelab", "nodes": 2, "quorate": 1, "version": 4],
            ["type": "node", "id": "node/\(node)", "name": node, "online": 1, "local": 1, "nodeid": 1, "ip": "10.0.0.11"],
            ["type": "node", "id": "node/\(secondNode)", "name": secondNode, "online": 1, "local": 0, "nodeid": 2, "ip": "10.0.0.12"],
        ]
    }

    static let usedVMIDs: Set<Int> = Set(guests.map(\.vmid))

    static func nextID() -> String {
        String((100...).first { !usedVMIDs.contains($0) } ?? 103)
    }

    static func pools() -> [[String: Any]] {
        [["poolid": "lab", "comment": "experiments"], ["poolid": "prod"]]
    }

    static func clusterOptions() -> [String: Any] {
        ["allowed-tags": ["web", "prod", "lab", "windows"], "keyboard": "en-us"]
    }

    /// `GET /nodes/{node}/storage?content=…&format=1`.
    static func nodeStorages(content: String?) -> [[String: Any]] {
        let list: [[String: Any]] = [
            ["storage": "local", "type": "dir", "content": "iso,vztmpl,backup,snippets,import", "active": 1, "enabled": 1, "shared": 0,
             "total": 93.9 * gib, "used": 21.4 * gib, "avail": 72.5 * gib,
             "formats": ["supported": ["raw", "qcow2", "vmdk", "subvol"], "default": "qcow2"]],
            ["storage": "local-zfs", "type": "zfspool", "content": "images,rootdir", "active": 1, "enabled": 1, "shared": 0,
             "total": 1.72 * 1024 * gib, "used": 412 * gib, "avail": 1.3 * 1024 * gib,
             "formats": ["supported": ["raw", "subvol"], "default": "raw"]],
        ]
        guard let content, !content.isEmpty else { return list }
        return list.filter { ($0["content"] as? String ?? "").split(separator: ",").contains { String($0) == content } }
    }

    /// Storage content honouring `content` and `vmid`, plus an import image on `local`.
    static func storageContent(_ name: String, content: String?, vmid: Int?) -> [[String: Any]] {
        var items = storageContent(name)
        if name == "local" {
            let now = Int(Date().timeIntervalSince1970)
            items.append(["volid": "local:backup/vzdump-qemu-100-2026_11_15-03_00_02.vma.zst", "content": "backup", "format": "vma.zst", "size": 2_040_109_465, "ctime": now - 86400 * 8 + 120, "vmid": 100, "subtype": "qemu", "notes": "debian-web"])
            items.append(["volid": "local:import/debian-13-genericcloud-amd64.qcow2", "content": "import", "format": "qcow2", "size": 412_000_000, "ctime": now - 86400 * 5])
        }
        if let content, !content.isEmpty {
            items = items.filter { ($0["content"] as? String) == content }
        }
        if let vmid {
            items = items.filter { ($0["vmid"] as? Int) == vmid }
        }
        return items
    }

    static func bridges() -> [[String: Any]] {
        [
            ["iface": "vmbr0", "type": "bridge", "active": 1, "comments": "LAN", "cidr": "10.0.0.11/24"],
            ["iface": "vmbr1", "type": "bridge", "active": 1, "comments": "DMZ"],
        ]
    }

    static func cpuModels() -> [[String: Any]] {
        let models: [(String, String)] = [
            ("EPYC-Genoa", "AuthenticAMD"), ("EPYC-Milan", "AuthenticAMD"), ("Skylake-Server", "GenuineIntel"),
            ("x86-64-v2-AES", "default"), ("x86-64-v3", "default"), ("x86-64-v4", "default"), ("kvm64", "default"), ("host", "default"), ("max", "default"),
        ]
        return models.map { ["name": $0.0, "vendor": $0.1, "custom": 0] }
    }

    static func cpuFlags() -> [[String: Any]] {
        [
            ["name": "aes", "description": "Activate AES instruction set for HW acceleration.", "supported-on": [node, secondNode]],
            ["name": "md-clear", "description": "Required to let the guest OS know if MDS is mitigated correctly", "supported-on": [node]],
            ["name": "nested-virt", "description": "Controls nested virtualization, namely 'svm' for AMD CPUs and 'vmx' for Intel CPUs.", "supported-on": []],
            ["name": "pcid", "description": "Meltdown fix cost reduction on Westmere, Sandy-, and IvyBridge Intel CPUs", "supported-on": []],
            ["name": "pdpe1gb", "description": "Allow guest OS to use 1GB size pages, if host HW supports it", "supported-on": [node, secondNode]],
        ]
    }

    static func vzdumpDefaults(storage: String?) -> [String: Any] {
        ["mode": "snapshot", "notes-template": "{{guestname}}", "notification-mode": "auto", "storage": storage ?? "local",
         "prune-backups": "keep-daily=7,keep-last=3,keep-weekly=4"]
    }

    static func extractConfig(volume: String) -> String {
        let vmid = BackupVolumeDemo.vmid(volume) ?? 100
        let guest = guests.first { $0.vmid == vmid }
        if volume.contains("lxc") {
            return "arch: amd64\ncores: \(guest?.cores ?? 1)\nhostname: \(guest?.name ?? "ct")\nmemory: \(Int((guest?.maxmem ?? gib) / 1_048_576))\nostype: debian\n"
        }
        return """
        #qmdump#map:scsi0:drive-scsi0:local-zfs:raw:
        bios: ovmf
        cores: \(guest?.cores ?? 2)
        memory: \(Int((guest?.maxmem ?? 2 * gib) / 1_048_576))
        meta: creation-qemu=10.1.2,ctime=1763000000
        name: \(guest?.name ?? "vm")
        sockets: 1
        """
    }

    /// Pending config: VM 100 has core and memory changes waiting for a restart.
    static func pending(type: String, vmid: Int) -> [[String: Any]] {
        let config = guestConfig(type: type, vmid: vmid)
        var rows: [[String: Any]] = config.compactMap { key, value in
            key == "digest" ? nil : ["key": key, "value": value]
        }
        if vmid == 100 {
            rows = rows.map { row in
                var row = row
                if row["key"] as? String == "cores" { row["pending"] = 6 }
                if row["key"] as? String == "memory" { row["pending"] = 12288 }
                return row
            }
        }
        return rows.sorted { ($0["key"] as? String ?? "") < ($1["key"] as? String ?? "") }
    }

    static let nodeNotes = """
    # pve

    Homelab main node.

    - **UPS**: APC 1500 (usb)
    - Backup to `local` nightly at 03:00
    """

    static func guestNotes(vmid: Int) -> String {
        vmid == 100 ? "## debian-web\n\nNginx + PHP. Public at `web.example.com`.\n\n1. Update monthly\n2. Snapshot before upgrades" : ""
    }

    /// Structured journal entries (`structured=1`), newest last, with cursors.
    static func journal(query: [String: String]) -> [[String: Any]] {
        let now = Date().timeIntervalSince1970
        let messages: [(String, Int?, String, Int)] = [
            ("systemd", 1, "Starting pve-daily-update.service - Daily PVE download activities...", 6),
            ("pveupdate", 21_034, "<root@pam> starting task UPID:pve:0000522A:aptupdate::root@pam:", 6),
            ("pveproxy", 1_402, "worker 1405 finished", 6),
            ("pvedaemon", 1_388, "<root@pam> successful auth for user 'root@pam'", 6),
            ("kernel", nil, "EXT4-fs (dm-1): mounted filesystem with ordered data mode.", 6),
            ("smartd", 912, "Device: /dev/nvme0, Temperature 47 Celsius reached limit of 45 Celsius", 4),
            ("pvestatd", 1_350, "storage 'nas-backup' is not online", 3),
            ("cron", 30_114, "(root) CMD (/usr/bin/vzdump 100 200 --mode snapshot --storage local --quiet 1)", 6),
            ("vzdump", 30_120, "INFO: Finished Backup of VM 100 (00:05:10)", 6),
            ("systemd", 1, "pve-daily-update.service: Deactivated successfully.", 6),
        ]
        let count = Int(query["lastentries"] ?? "") ?? 500
        var entries: [[String: Any]] = [["ty": "cursor", "c": "s=demo;i=old"], ["ty": "host", "h": node]]
        let older = query["endcursor"] != nil
        let total = min(count, older ? 40 : 60)
        for index in 0..<total {
            let message = messages[index % messages.count]
            let offset = Double(total - index) * 37 + (older ? 4_000 : 0)
            var entry: [String: Any] = ["t": Int((now - offset) * 1_000_000), "id": message.0, "msg": message.2, "p": message.3]
            if let pid = message.1 { entry["pid"] = pid }
            entries.append(entry)
            if index == total / 2 && !older { entries.append(["ty": "reboot", "t": Int((now - offset + 5) * 1_000_000)]) }
        }
        entries.append(["ty": "cursor", "c": "s=demo;i=new"])
        return entries
    }

    static func aptUpdates() -> [[String: Any]] {
        [
            ["Package": "proxmox-kernel-7.0.15-1-pve-signed", "Title": "Proxmox Kernel Image (signed)", "Version": "7.0.15-1", "Origin": "Proxmox", "Arch": "amd64", "Priority": "optional", "Section": "kernel"],
            ["Package": "pve-manager", "Title": "Proxmox Virtual Environment Management Tools", "OldVersion": "9.2.21", "Version": "9.2.22", "Origin": "Proxmox", "Arch": "amd64"],
            ["Package": "qemu-server", "Title": "Qemu Server Tools", "OldVersion": "9.1.8", "Version": "9.1.9", "Origin": "Proxmox", "Arch": "amd64"],
            ["Package": "zfsutils-linux", "Title": "command-line tools to manage OpenZFS filesystems", "OldVersion": "2.3.4-pve1", "Version": "2.3.5-pve1", "Origin": "Proxmox", "Arch": "amd64"],
            ["Package": "curl", "Title": "command line tool for transferring data with URL syntax", "OldVersion": "8.14.1-2", "Version": "8.14.1-2+deb13u1", "Origin": "Debian", "Arch": "amd64"],
            ["Package": "openssh-server", "Title": "secure shell (SSH) server", "OldVersion": "1:10.0p1-7", "Version": "1:10.0p1-7+deb13u1", "Origin": "Debian", "Arch": "amd64"],
        ]
    }

    static func changelog(name: String) -> String {
        """
        \(name) (new version) trixie; urgency=medium

          * fix a crash when the guest config contains an empty line

          * update translations

         -- Proxmox Support Team <support@proxmox.com>  Mon, 23 Nov 2026 10:00:00 +0100
        """
    }

    static func haStatus() -> [[String: Any]] {
        [
            ["id": "quorum", "type": "quorum", "node": node, "status": "OK", "quorate": 1],
            ["id": "master", "type": "master", "node": node, "status": "\(node) (active, \(Date().formatted(date: .abbreviated, time: .standard)))"],
            ["id": "lrm:\(node)", "type": "lrm", "node": node, "status": "\(node) (active, \(Date().formatted(date: .abbreviated, time: .standard)))"],
            ["id": "lrm:\(secondNode)", "type": "lrm", "node": secondNode, "status": "\(secondNode) (idle)"],
            ["id": "service:vm:100", "type": "service", "sid": "vm:100", "node": node, "state": "started", "crm_state": "started", "request_state": "started", "status": "vm:100 (\(node), started)"],
            ["id": "service:ct:200", "type": "service", "sid": "ct:200", "node": node, "state": "started", "crm_state": "started", "request_state": "started", "status": "ct:200 (\(node), started)"],
        ]
    }

    static func haResources() -> [[String: Any]] {
        [
            ["sid": "vm:100", "type": "vm", "state": "started", "max_restart": 1, "max_relocate": 1],
            ["sid": "ct:200", "type": "ct", "state": "started", "comment": "DNS"],
        ]
    }

    static func replicationJobs() -> [[String: Any]] {
        [
            ["id": "100-0", "type": "local", "guest": 100, "jobnum": 0, "target": secondNode, "schedule": "*/15", "source": node],
            ["id": "200-0", "type": "local", "guest": 200, "jobnum": 0, "target": secondNode, "schedule": "*/30", "comment": "DNS"],
        ]
    }

    static func replicationStatus() -> [[String: Any]] {
        let now = Int(Date().timeIntervalSince1970)
        return [
            ["id": "100-0", "guest": 100, "target": secondNode, "last_sync": now - 420, "next_sync": now + 480, "duration": 6.82, "fail_count": 0, "last_try": now - 420],
            ["id": "200-0", "guest": 200, "target": secondNode, "last_sync": now - 7_200, "next_sync": now + 300, "duration": 2.1, "fail_count": 2, "error": "command 'zfs snapshot rpool/data/subvol-200-disk-0@__replicate_200-0_1764000000__' failed: dataset is busy"],
        ]
    }

    static func firewallOptions(scope: String) -> [String: Any] {
        scope == "cluster" ? ["enable": 0, "policy_in": "DROP", "policy_out": "ACCEPT"] : ["enable": 1, "policy_in": "DROP"]
    }

    static func firewallRules(scope: String) -> [[String: Any]] {
        switch scope {
        case "cluster":
            return [
                ["pos": 0, "type": "in", "action": "ACCEPT", "macro": "SSH", "source": "10.0.0.0/24", "enable": 1, "comment": "管理网 SSH"],
                ["pos": 1, "type": "in", "action": "ACCEPT", "proto": "tcp", "dport": "8006", "source": "10.0.0.0/24", "enable": 1, "comment": "WebUI / API"],
                ["pos": 2, "type": "in", "action": "ACCEPT", "proto": "icmp", "enable": 1],
                ["pos": 3, "type": "group", "action": "monitoring", "enable": 0],
            ]
        case "node":
            return [["pos": 0, "type": "in", "action": "ACCEPT", "proto": "udp", "dport": "5405:5412", "source": "10.0.0.0/24", "enable": 1, "comment": "corosync"]]
        default:
            return [
                ["pos": 0, "type": "in", "action": "ACCEPT", "macro": "HTTPS", "enable": 1],
                ["pos": 1, "type": "in", "action": "ACCEPT", "macro": "HTTP", "enable": 1],
                ["pos": 2, "type": "out", "action": "DROP", "dest": "10.0.0.0/24", "enable": 1, "comment": "keep the DMZ out of the LAN"],
            ]
        }
    }

    static func migrationCheck(vmid: Int) -> [String: Any] {
        let guest = guests.first { $0.vmid == vmid }
        return [
            "running": guest?.status == "running" ? 1 : 0,
            "allowed_nodes": [secondNode],
            "not_allowed_nodes": [:] as [String: Any],
            "local_disks": [["volid": "local-zfs:vm-\(vmid)-disk-0", "size": guest?.maxdisk ?? 0, "cdrom": 0, "is_unused": 0]],
            "local_resources": [],
            "mapped-resources": [],
        ]
    }

    /// Log of a demo vzdump task, with the mode the backup used.
    static func vzdumpLog(objectID: String) -> [String] {
        let mode = objectID == "200" ? "stop" : "snapshot"
        return [
            "INFO: starting new backup job: vzdump \(objectID) --mode \(mode) --storage local --compress zstd",
            "INFO: Starting Backup of VM \(objectID) (\(objectID == "200" ? "lxc" : "qemu"))",
            "INFO: backup mode: \(mode)",
            "INFO: creating vzdump archive",
            "INFO: Finished Backup of VM \(objectID)",
            "TASK OK",
        ]
    }
}

/// VMID from a backup volume name (demo only).
enum BackupVolumeDemo {
    static func vmid(_ volid: String) -> Int? {
        guard let range = volid.range(of: #"-(qemu|lxc)-(\d+)-"#, options: .regularExpression) else { return nil }
        return volid[range].split(separator: "-").compactMap { Int($0) }.first
    }
}
