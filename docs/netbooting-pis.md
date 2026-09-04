# Netbooting the Raspberry Pis into Talos

How a Pi 4 gets from "Ubuntu on a USB SSD" to "Talos on that SSD" without an
SD card, a keyboard or a serial cable — and what to look at when it doesn't.

The design in one line: **the Pi's EEPROM always tries the network first;
dnsmasq decides per boot whether to answer.** Answered → u-boot → Talos
maintenance mode (RAM) → install. Ignored → the firmware times out → USB →
whatever is on the disk. The PXE server is never a boot dependency for the
cluster; it is only the path *into* a (re)install.

Everything below was exercised on real hardware during the first cutover.

## Boot order, hop by hop

`<operator>` is the PXE server (`pxe_server_ip`); `<mac>` is the Pi's NIC MAC
as NetBox has it.

| # | Who | What happens | Where to see it |
|---|---|---|---|
| 1 | EEPROM | `BOOT_ORDER=0xf42`, read right-to-left: **network**, then **USB**, then **restart** the list. Set once per Pi by `make apply-pi-eeprom` (or by `apply-pi-cutover`). | `sudo rpi-eeprom-config` on the Pi while it still runs Linux |
| 2 | Pi firmware | DHCP with `client-arch 0`, vendor class `PXEClient:Arch:00000:UNDI:002001`. | `docker logs files-dnsmasq-1` → `PXE(<if>) <mac> proxy` (offered) or `… proxy-ignored` (not in the provision list) |
| 3 | dnsmasq | Pi is in `talos_pi_provision_hosts` → `pxe-service "Raspberry Pi Boot"`; otherwise `dhcp-ignore` — total silence. | same log; `dhcp-mac=set:provision,<mac>` lines in the rendered `dnsmasq.conf` |
| 4 | Pi firmware | **Ignored** → ~30–60 s network timeout → USB → local disk. **Offered** → TFTP `<serial>/start4.elf` (not found — normal), `start4.elf`, `config.txt`, `fixup4.dat`, `bcm2711-rpi-4-b.dtb`, `u-boot.bin`. | `dnsmasq-tftp: sent /var/tftp/…`. "Early terminate" / "failed sending" pairs and "not found" for `pieeprom.sig`, `recovery.elf`, `dt-blob.bin`, `cmdline.txt`, `armstub8-gic.bin`, `overlays/…` are **normal** — the firmware sizes files then re-fetches. |
| 5 | u-boot | Baked `bootcmd`: `dhcp` (vendor class `U-Boot.armv8`) → `wget /boot/uboot.scr` from `<operator>` → `source` it. Any failure → `reset` → back to hop 2. | `docker logs files-caddy-1` → `GET /boot/uboot.scr` (console-format log, not JSON) |
| 6 | `uboot.scr` | `wget /talos/<ver>/vmlinuz-arm64.raw` (77 MB, flat Image) and `initramfs-arm64.xz` (65 MB, actually zstd) → `booti` with `talos_kernel_cmdline`. | Caddy: the two `GET`s ~2–4 s apart. A repeat `GET /boot/uboot.scr` within a minute means `booti` failed and `reset` fired. |
| 7 | Talos (RAM) | Maintenance mode: transient DHCP lease, `apid` on `:50000`, `--insecure` API only. | `talosctl -n <lease-ip> get machinestatus --insecure` → `STAGE maintenance READY true` |
| 8 | `apply-config` | Talos pulls the Image Factory installer, writes `/dev/sda`, reboots. ~30 s once the image is cached. | only visible with log shipping — see *Seeing inside the RAM-booted node* |
| 9 | EEPROM → dnsmasq | Same as 1–3. With the Pi **no longer** in the list: `proxy-ignored` → USB → **Talos from disk**, static NetBox IP via the MAC `deviceSelector`. | `ping <netbox-ip>`; port 22 closed (Ubuntu gone); `apid` opens only once the control plane exists |

Timing on a Pi 4 with a healthy operator: hop 2→7 ≈ 70–80 s; hop 8 ≈ 30 s
after the installer image is cached; hop 9 ≈ 2 min to `kubelet` healthy.

## The cutover, in order

The ordering matters in exactly one place: **the gate is closed before the
install starts.** Closing it only affects the *next* boot, so it cannot
disturb a node sitting in maintenance — and it guarantees the post-install
reboot lands on the disk rather than back in maintenance.

```
stage EEPROM 0xf42  →  open gate  →  reboot  →  wait: maintenance
                    →  CLOSE gate →  apply-config  →  wait: Talos on disk
```

`playbooks/pi-cutover.yaml` does all of it for one Pi or a batch:

```bash
# Prerequisites: the Pi runs Ubuntu with SSH as admin + passwordless sudo,
# the operator's ~/.ssh/id_rsa is authorised there, NetBox has the Pi as
# device_type pi-*, tag pxe, platform talos, with its MAC and primary IP.

make -C ansible check-pi-cutover EXTRA_VARS='{"pi_cutover_hosts": ["Zond", "Mir"]}'
make -C ansible apply-pi-cutover EXTRA_VARS='{"pi_cutover_hosts": ["Zond", "Mir"]}'
```

Targets are a **JSON list**, not `LIMIT` — the localhost plays and the SOPS
loader must see every host. (`key=[...]` would arrive as a string; the
object form is required.)

Order for the fleet: workers first, the control-plane Pi (`kosmos`) last,
then `make apply-talos TAGS=bootstrap,kubeconfig` once **all** control-plane
nodes (VMs and Pi) have their config. Until then every worker's `apid` stays
closed — that is expected, not a fault.

Doing it by hand, the same steps are:

```bash
make -C ansible apply-pi-eeprom LIMIT=Zond                                             # stage 0xf42
make -C ansible apply-pxe TAGS=pxe-server EXTRA_VARS='{"talos_pi_provision_hosts": ["Zond"]}'
ssh admin@<zond-ip> sudo reboot                                                        # → maintenance
make -C ansible apply-pxe TAGS=pxe-server EXTRA_VARS='{"talos_pi_provision_hosts": []}' # CLOSE first
make -C ansible apply-talos LIMIT=localhost,Zond TAGS=config,apply                     # install
```

`TAGS=pxe-server` runs only the PXE-server plays. Do **not** use
`LIMIT=localhost` for that: it skips the play that loads each NUC's SOPS
`root_password`, and the preseed render then fails before the Pi tasks.

## Seeing inside the RAM-booted node

Maintenance mode allows only `apply-config`, `version` and `get`; `dmesg`,
`logs` and `events` need the secured API, which does not exist yet. When an
install fails, the node reboots and takes its logs with it. Two knobs make
it observable, both temporary:

1. **Service logs** (the install sequence, phase by phase): patch the
   node's config with a UDP destination and apply that copy instead:
   ```bash
   cat > /tmp/log-patch.yaml <<EOF
   machine:
     logging:
       destinations:
         - endpoint: udp://<operator>:6050
           format: json_lines
   EOF
   talosctl machineconfig patch .talos/clusterconfig/homelab-Zond.yaml \
     --patch @/tmp/log-patch.yaml -o /tmp/homelab-Zond-log.yaml
   talosctl -n <lease-ip> apply-config --insecure -f /tmp/homelab-Zond-log.yaml
   ```
   Any UDP sink works (`socat -u UDP-RECV:6050 CREATE:/tmp/talos.log`, or a
   ten-line Python script). Lines are JSON; the useful ones carry
   `[talos] phase install …`, `task install (1/1): …`, and an `error` field.
   The destination persists into the installed system; the role's next
   `apply` normalises it away.
2. **Kernel log** (drivers, USB, the disk): add
   `talos.logging.kernel=udp://<operator>:6050` to the netboot cmdline for one
   boot by overriding `talos_kernel_cmdline` in `EXTRA_VARS` (keep the
   existing arguments, including the USB quirk). Records arrive with
   `"facility": "kern"`.

## Troubleshooting

**Pi never appears in the dnsmasq log.** Its DHCP isn't reaching the
operator: wrong VLAN/L2 segment, or `BOOT_ORDER` still USB-first (check with
`rpi-eeprom-config`; the staged change only flashes on a reboot). A Pi with
no OS at all sits in the `0xf42` restart loop and keeps trying network every
cycle — add it to the provision list and it netboots on the next pass, no
power-cycle needed.

**`proxy-ignored` when you expected netboot.** The Pi is not in
`talos_pi_provision_hosts` **as dnsmasq sees it**. Confirm with
`docker exec files-dnsmasq-1 grep set:provision /etc/dnsmasq.conf` — not the
file on disk. See *dnsmasq is serving a stale config* below.

**dnsmasq is serving a stale config.** Ansible writes `dnsmasq.conf`
atomically (new inode); the container's single-file bind mount keeps the
**old** inode until the container restarts. The `Restart dnsmasq` handler
does that — but if a later task in the same play failed, older versions of
`pxe.yaml` dropped the handler. Compare inodes (`stat` on the host vs
`docker exec … stat /etc/dnsmasq.conf`); `docker restart files-dnsmasq-1`
fixes it. The play now runs with `force_handlers: true`.

**TFTP sends `u-boot.bin`, then nothing on HTTP.** u-boot is running but its
`wget` isn't reaching Caddy. Check the baked `serverip`:
`strings tftp/u-boot.bin | grep ^bootcmd=` — it must be the operator's
current address. The build stamp is keyed on `pxe_server_ip`, so
`make apply-pxe TAGS=pxe-server` after an operator IP change rebuilds it; the
`Verify u-boot.bin …` assert refuses a stale binary. Also check Caddy's log
in its **console** format — a JSON-shaped filter sees nothing.

**HTTP fetches happen, then `uboot.scr` is fetched again a minute later.**
`booti` failed and `reset` fired. Almost always a dispatcher/kernel problem:
check `vmlinuz-arm64.raw` has `ARM\x64` at offset `0x38`
(`od -An -c -j 56 -N 4`), that the initramfs fetched completely, and that
`bcm2711-rpi-4-b.dtb` was served (u-boot's `${fdt_addr}` comes from it — no
DTB, no `booti`). A serial cable on the mini-UART (`enable_uart=1` is set)
shows u-boot's own messages.

**A `wget` fails and the Pi retries.** Seen once for the 65 MB initramfs:
u-boot's TCP stack gave up, `reset` fired, the second pass succeeded. The
loop is the recovery; only worry if it repeats.

**Maintenance mode reached, `apply-config` "succeeded", Pi came back on
Ubuntu.** The install failed and the node rebooted (fatal sequencer errors
reboot). Recover the *why* with the log shipping above. The one we hit:

**`xhci_hcd … Host System Error … HC died`, `usb 3-1: USB disconnect`,
`[sda] Synchronizing SCSI cache`, then `task "upgrade" failed: exit code 1`.**
The enclosures' Realtek RTL9210 bridge, driven by UAS on Talos's upstream
kernel, kills the Pi 4's xHCI controller under the installer's write load.
Ubuntu survives on identical hardware only because the downstream Raspberry
Pi kernel carries VL805 workarounds (`xhci quirks 0x000e2000…` vs `0x0`).
Fix in place: `usb-storage.quirks=0bda:9210:u` on the netboot cmdline
(`talos_pi_usb_storage_quirks` in the `00-pxe` defaults) **and** in
`machine.install.extraKernelArgs` (same var in the `talos` role). A
different enclosure needs its own `VID:PID` — `lsusb` on the Pi while it
still runs Linux.

**Install succeeded, Pi came back in maintenance mode instead of on disk.**
It was still in the provision list when it rebooted. Close the gate
(`talos_pi_provision_hosts: []` + apply) and reboot it — there is no
insecure reboot API, so either power-cycle it or apply the config again and
let the post-install reboot fall through this time. `pi-cutover.yaml`
avoids this by closing the gate before `apply-config`.

**Install succeeded, node answers at its NetBox IP, port 50000 closed.**
Normal for a worker until the control plane is bootstrapped: `apid` gets its
certificate from `trustd` on the control plane. Port 22 closed confirms the
old OS is gone; the shipped logs (if enabled) show `loading config from
STATE`, `assigned address <netbox-ip>`, `kubelet … Health check successful`.

**`apply-talos` fails with "arp-scan: not found" or finds no node.** Install
`arp-scan` on the operator (it lives in `/usr/sbin`; the task uses `become`,
so `sudo`'s path finds it). The scan matches the NetBox MAC against live
leases; a node that hasn't finished booting yet isn't there — wait for
`get machinestatus --insecure` first.

**`make apply-pxe` fails on `Render per-host Debian preseed` with
`root_password` undefined.** You used `LIMIT=localhost`. Use
`TAGS=pxe-server`.

**The assert `Refuse unknown names in talos_pi_provision_hosts` fails with a
list of single characters.** The var arrived as a string:
`EXTRA_VARS='talos_pi_provision_hosts=["Zond"]'`. Use the JSON-object form
`EXTRA_VARS='{"talos_pi_provision_hosts": ["Zond"]}'`.

**A Pi is stuck in an endless u-boot loop from an older dispatcher.** Older
dispatchers had a "no entry → sleep 60 → reset" branch. Power-cycle it;
with the gate closed it falls through to its disk on the way back up.

**Image Factory is slow.** `factory.talos.dev` builds assets lazily on first
request and has timed out both `get_url` (now `timeout: 120`, and skipped
when the file exists) and the installer image pull inside the node (Talos
retries by itself; give it a minute before reading the logs).

**Something still on Ubuntu needs a look.** SSH as `admin` while it lasts;
after `apply-config` there is no SSH and the disk is Talos.

## Reference

- `ansible/roles/00-pxe/templates/dnsmasq.conf.j2` — the gate.
- `ansible/roles/00-pxe/templates/uboot-fragment.config.j2` — what the
  operator bakes into `u-boot.bin`.
- `ansible/roles/00-pxe/templates/uboot.cmd.j2` — the dispatcher.
- `ansible/roles/00-pxe/files/unwrap-zboot.sh` — why the kernel is `.raw`.
- `ansible/playbooks/pi-cutover.yaml`, `pi-eeprom-netboot.yaml` — the tools.
- [`talos-bootstrap.md`](./talos-bootstrap.md) — the cluster side.
- [`pxe-flow.md`](./pxe-flow.md) — the x86 path and how the role is laid out.
