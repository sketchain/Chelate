import Foundation
import Testing
@testable import PVEKit

@Suite("Create VM / CT wizards")
struct CreateWizardTests {
    let lvm = NodeStorage(storage: "local-lvm", type: "lvmthin", content: ["images", "rootdir"])
    let dir = NodeStorage(storage: "local", type: "dir", content: ["images", "iso"], supportedFormats: [.raw, .qcow2, .vmdk], defaultFormat: .qcow2)

    func fields(_ parameters: [(String, String)]) -> [String: String] {
        Dictionary(parameters, uniquingKeysWith: { _, last in last })
    }

    func linuxVM() -> VMWizard {
        var wizard = VMWizard()
        wizard.node = "pve"
        wizard.vmid = 105
        wizard.bridge = "vmbr0"
        wizard.isoStorage = "local"
        wizard.isoVolume = "local:iso/debian-13.iso"
        wizard.addDisk(storage: lvm)
        wizard.applyOSType("l26")
        wizard.applySystemDefaultsIfNeeded()
        wizard.applyMemoryDefaultsIfNeeded()
        return wizard
    }

    @Test func defaultLinuxVM() {
        let wizard = linuxVM()
        #expect(wizard.disks.first?.key == "scsi0", "the single disk follows the OS bus")
        #expect(wizard.model == "virtio")
        let request = fields(wizard.request().parameters)
        #expect(request["vmid"] == "105")
        #expect(request["ide2"] == "local:iso/debian-13.iso,media=cdrom")
        #expect(request["ostype"] == "l26")
        #expect(request["scsihw"] == "virtio-scsi-single")
        #expect(request["scsi0"] == "local-lvm:32,iothread=on")
        #expect(request["sockets"] == "1")
        #expect(request["cores"] == "1")
        #expect(request["cpu"] == "x86-64-v2-AES")
        #expect(request["numa"] == "0", "numa is always submitted")
        #expect(request["memory"] == "2048")
        #expect(request["balloon"] == nil)
        #expect(request["net0"] == "virtio,bridge=vmbr0,firewall=1")
        for key in ["name", "pool", "onboot", "startup", "arch", "kvm", "tags", "machine", "bios", "efidisk0", "agent", "tpmstate0", "boot", "start", "vga", "allow-ksm"] {
            #expect(request[key] == nil, "\(key) is omitted by default")
        }
        for step in VMWizardStep.allCases {
            #expect(wizard.problems(step).isEmpty, "\(step)")
        }
    }

    @Test func windows11VM() {
        var wizard = VMWizard()
        wizard.node = "pve"
        wizard.vmid = 106
        wizard.bridge = "vmbr0"
        wizard.addDisk(storage: dir)
        wizard.applyOSType("win11")
        wizard.media = .none
        wizard.setVirtIODriversCD(true)
        wizard.driversStorage = "local"
        wizard.driversVolume = "local:iso/virtio-win.iso"
        wizard.applySystemDefaultsIfNeeded()
        wizard.efi.select(lvm)
        wizard.tpm.select(dir)
        wizard.applyMemoryDefaultsIfNeeded()
        #expect(wizard.machine == "q35")
        #expect(wizard.bios == "ovmf")
        #expect(wizard.addTPM)
        #expect(wizard.memory == 4096)
        let request = fields(wizard.request().parameters)
        #expect(request["ide2"] == "none,media=cdrom")
        #expect(request["ide0"] == "local:iso/virtio-win.iso,media=cdrom")
        #expect(request["scsi0"] == "local:32,format=qcow2,iothread=on")
        #expect(request["boot"] == "order=scsi0;ide2;ide0;net0")
        #expect(request["machine"] == "q35")
        #expect(request["bios"] == "ovmf")
        #expect(request["efidisk0"] == "local-lvm:1,efitype=4m,pre-enrolled-keys=1")
        #expect(request["tpmstate0"] == "local:1,format=qcow2,version=v2.0")
        #expect(request["net0"] == "virtio,bridge=vmbr0,firewall=1")
        #expect(request["memory"] == "4096")
    }

    @Test func memoryBalloonAndShares() {
        var wizard = linuxVM()
        wizard.setMemory(4096)
        #expect(wizard.balloon == 4096, "balloon follows memory while equal")
        wizard.balloon = 1024
        wizard.shares = 500
        wizard.setMemory(8192)
        #expect(wizard.balloon == 1024)
        var request = fields(wizard.request().parameters)
        #expect(request["balloon"] == "1024")
        #expect(request["shares"] == "500")
        wizard.ballooning = false
        wizard.allowKSM = false
        request = fields(wizard.request().parameters)
        #expect(request["balloon"] == "0")
        #expect(request["shares"] == nil)
        #expect(request["allow-ksm"] == "0")
        wizard.ballooning = true
        wizard.balloon = 9000
        #expect(!wizard.problems(.memory).isEmpty)
    }

    @Test func advancedGeneralAndCPU() {
        var wizard = linuxVM()
        wizard.name = "web-01"
        wizard.onboot = true
        wizard.order = "2"
        wizard.down = "60"
        wizard.arch = .aarch64
        wizard.normalizeForArch()
        wizard.tags = ["web", "prod"]
        wizard.cputype = "host"
        wizard.flags = ["pcid": .off, "aes": .on, "md-clear": .default]
        wizard.vcpus = 1
        wizard.isRootUser = true
        wizard.affinity = "0-3,8"
        wizard.cpuunits = 100
        let request = fields(wizard.request().parameters)
        #expect(request["startup"] == "order=2,down=60")
        #expect(request["arch"] == "aarch64")
        #expect(request["kvm"] == "0", "non-host architecture runs emulated")
        #expect(request["tags"] == "web;prod")
        #expect(request["scsi2"] == "local:iso/debian-13.iso,media=cdrom", "ARM install drive is scsi2")
        #expect(request["ide2"] == nil)
        #expect(request["cpu"] == "host,flags=+aes;-pcid")
        #expect(request["affinity"] == "0-3,8")
        #expect(request["cpuunits"] == nil, "default CPU units are omitted")
        wizard.isRootUser = false
        #expect(fields(wizard.request().parameters)["affinity"] == nil, "only root@pam can set affinity")
        wizard.vcpus = 5
        #expect(wizard.problems(.cpu).contains { $0.field == "vcpus" })
    }

    @Test func diskSlotsAndOptions() throws {
        var wizard = linuxVM()
        wizard.addDisk(storage: lvm)
        #expect(wizard.sortedDisks.map(\.key) == ["scsi0", "scsi1"])
        let id = try #require(wizard.disks.last?.id)
        wizard.setBus(of: id, to: .ide)
        #expect(wizard.disks.last?.key == "ide0", "ide2 is the install drive")
        #expect(wizard.disks.last?.iothread == false)
        wizard.setBus(of: id, to: .virtio)
        var disk = try #require(wizard.disks.last)
        #expect(disk.iothread)
        disk.ssd = true
        disk.readOnly = true
        disk.backup = false
        disk.skipReplication = true
        disk.discard = true
        disk.cache = "writeback"
        disk.aio = "native"
        disk.mbpsRd = 100
        disk.iopsWrMax = 500
        disk.size = 64
        #expect(disk.configString == "local-lvm:64,backup=0,replicate=no,discard=on,iothread=on,ro=on,cache=writeback,aio=native,mbps_rd=100,iops_wr_max=500")
        var imported = VMDiskDraft(bus: .scsi, device: 1, isImport: true)
        imported.target.select(lvm)
        imported.importStorage = "local"
        imported.importFrom = "local:import/disk.qcow2"
        imported.normalizeForBus(scsihw: "virtio-scsi-single")
        #expect(imported.configString == "local-lvm:0,import-from=local:import/disk.qcow2,iothread=on")
        wizard.disks.removeAll()
        #expect(wizard.problems(.disks).isEmpty, "no disks is allowed")
        #expect(fields(wizard.request().parameters)["scsi0"] == nil)
    }

    @Test func networkOptions() {
        var wizard = linuxVM()
        wizard.macAddress = "BC:24:11:12:34:56"
        wizard.bridge = "vmbr1"
        wizard.vlanTag = 10
        wizard.rate = 12.5
        wizard.queues = 4
        wizard.disconnect = true
        wizard.mtu = 1
        #expect(wizard.net0 == "virtio=BC:24:11:12:34:56,bridge=vmbr1,tag=10,firewall=1,rate=12.5,queues=4,link_down=1,mtu=1")
        wizard.mtu = 500
        #expect(wizard.problems(.network).contains { $0.field == "mtu" })
        wizard.noNetwork = true
        #expect(fields(wizard.request().parameters)["net0"] == nil)
        #expect(wizard.problems(.network).isEmpty)
        wizard.vga = "serial0"
        let request = fields(wizard.request().parameters)
        #expect(request["vga"] == "serial0")
        #expect(request["serial0"] == "socket")
    }

    @Test func confirmGroups() {
        let wizard = linuxVM()
        #expect(wizard.settings(for: .general).map(\.key) == ["nodename", "vmid"])
        #expect(wizard.settings(for: .disks).map(\.value) == ["local-lvm:32,iothread=on"])
        #expect(wizard.settings(for: .cpu).map(\.key) == ["sockets", "cores", "cpu", "numa"])
    }

    @Test func validators() {
        #expect(WizardValidation.isDNSName("web-01.example.com"))
        #expect(!WizardValidation.isDNSName("-bad"))
        #expect(WizardValidation.isIPv4CIDR("192.168.1.50/24"))
        #expect(!WizardValidation.isIPv4CIDR("192.168.1.50/4"))
        #expect(!WizardValidation.isIPv4("256.1.1.1"))
        #expect(WizardValidation.isIPv6("2001:db8::1"))
        #expect(WizardValidation.isIPv6("::ffff:192.168.1.1"))
        #expect(!WizardValidation.isIPv6("2001:db8::1::2"))
        #expect(WizardValidation.isIPv6CIDR("2001:db8::50/64"))
        #expect(WizardValidation.isMAC("bc:24:11:aa:bb:cc"))
        #expect(WizardValidation.isAddressList("1.1.1.1, 2606:4700:4700::1111;fe80::1%vmbr0"))
        #expect(!WizardValidation.isAddressList("2001:db8::1%eth0"))
        #expect(WizardValidation.isSSHKey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI user@host"))
        #expect(WizardValidation.isSSHKey("command=\"x\" ssh-rsa AAAAB3Nza user"))
        #expect(!WizardValidation.isSSHKey("not a key"))
        #expect(WizardValidation.isTag("Prod_1"))
        #expect(!WizardValidation.isTag("bad tag"))
    }

    func container() -> CTWizard {
        var wizard = CTWizard()
        wizard.node = "pve"
        wizard.vmid = 210
        wizard.password = "secret"
        wizard.confirmPassword = "secret"
        wizard.templateStorage = "local"
        wizard.ostemplate = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
        wizard.mounts[0].storage = "local-lvm"
        wizard.mounts[0].storageType = "lvmthin"
        wizard.bridge = "vmbr0"
        return wizard
    }

    @Test func defaultContainer() {
        let wizard = container()
        let request = fields(wizard.request().parameters)
        #expect(request["vmid"] == "210")
        #expect(request["ostemplate"] == "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst")
        #expect(request["unprivileged"] == "1")
        #expect(request["features"] == "nesting=1")
        #expect(request["password"] == "secret")
        #expect(request["rootfs"] == "local-lvm:8")
        #expect(request["cores"] == "1")
        #expect(request["memory"] == "512")
        #expect(request["swap"] == "512")
        #expect(request["net0"] == "name=eth0,bridge=vmbr0,firewall=1")
        for step in CTWizardStep.allCases {
            #expect(wizard.problems(step).isEmpty, "\(step)")
        }
        #expect(!wizard.settings(for: .general).contains { $0.value == "secret" })
    }

    @Test func privilegedContainerWithMountsAndNetwork() throws {
        var wizard = container()
        wizard.setUnprivileged(false)
        #expect(!wizard.nesting)
        wizard.setUnprivileged(true)
        #expect(!wizard.nesting, "nesting is not restored")
        wizard.setUnprivileged(false)
        wizard.mounts[0].mountOptions = ["noatime", "nodev", "discard"]
        wizard.mounts[0].quota = true
        let added = wizard.addMountPoint(storage: NodeStorage(storage: "tank", type: "zfspool", content: ["rootdir"]))
        let id = try #require(added)
        let index = try #require(wizard.mounts.firstIndex { $0.id == id })
        wizard.mounts[index].path = "/data"
        wizard.mounts[index].size = 32
        wizard.mounts[index].quota = true
        wizard.mounts[index].acl = false
        wizard.mounts[index].idmap = [IDMapRow(type: "u", containerID: 0, hostID: 100000, size: 65536), IDMapRow(type: "g")]
        wizard.ipv4Mode = .dhcp
        wizard.ipv6Mode = .auto
        wizard.nameservers = "1.1.1.1, 2606:4700:4700::1111"
        wizard.searchDomain = "lan"
        wizard.cores = nil
        let request = fields(wizard.request().parameters)
        #expect(request["unprivileged"] == "0")
        #expect(request["features"] == nil)
        #expect(request["rootfs"] == "local-lvm:8,mountoptions=noatime;discard,quota=1", "nodev is not a rootfs option")
        #expect(request["mp0"] == "tank:32,mp=/data,backup=1,acl=0,idmap=u:0:100000:65536", "no quota on ZFS")
        #expect(request["net0"] == "name=eth0,bridge=vmbr0,firewall=1,ip=dhcp,ip6=auto")
        #expect(request["nameserver"] == "1.1.1.1 2606:4700:4700::1111")
        #expect(request["searchdomain"] == "lan")
        #expect(request["cores"] == nil)
    }

    @Test func containerValidation() {
        var wizard = container()
        wizard.password = ""
        wizard.confirmPassword = ""
        #expect(wizard.problems(.general).contains { $0.field == "password" })
        wizard.sshKeys = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI me"
        #expect(wizard.problems(.general).isEmpty)
        wizard.password = "abc"
        #expect(wizard.problems(.general).contains { $0.field == "confirmpw" })
        wizard.ipv4 = "10.0.0.5"
        #expect(wizard.problems(.network).contains { $0.field == "ip" })
        #expect(CTWizard.templateArch("local:vztmpl/alpine-3.22-default_20250617_arm64.tar.xz") == "arm64")
        wizard.nodeArch = "amd64"
        #expect(!wizard.showsTemplate("local:vztmpl/alpine-3.22-default_20250617_arm64.tar.xz"))
        #expect(wizard.showsTemplate("local:vztmpl/custom.tar.gz"))
    }
}
