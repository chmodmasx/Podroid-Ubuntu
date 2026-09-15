<div align="center">

<img src="docs/logo.png" alt="Podroid logo" width="120" />

# Podroid Ubuntu

**Run Linux containers and a full Ubuntu environment on your Android phone. No root.**

A real Ubuntu 26.04 LTS ARM64 VM with its own kernel — not a chroot or proot trick — so **Podman, Docker and LXC** behave like they do on a server.

[![Release](https://img.shields.io/github/v/release/ExTV/Podroid?include_prereleases&style=flat-square&label=upstream&color=blue)](https://github.com/ExTV/Podroid/releases)
[![Stars](https://img.shields.io/github/stars/chmodmasx/Podroid-Ubuntu?style=flat-square&color=yellow)](https://github.com/chmodmasx/Podroid-Ubuntu/stargazers)
[![License](https://img.shields.io/github/license/chmodmasx/Podroid-Ubuntu?style=flat-square)](LICENSE)
![Android 8+](https://img.shields.io/badge/Android-8%2B-3DDC84?style=flat-square&logo=android&logoColor=white)
![Ubuntu 26.04](https://img.shields.io/badge/guest-Ubuntu%2026.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)
![arm64](https://img.shields.io/badge/arch-arm64-orange?style=flat-square)

[**Upstream website**](https://extv.github.io/Podroid/) · [**Upstream documentation**](https://extv.github.io/Podroid/guide/)

<table>
  <tr>
    <td align="center" width="25%"><img src="docs/screenshots/01-home-idle.png" alt="Home screen before the VM starts" width="190" /><br /><sub><b>Home</b></sub></td>
    <td align="center" width="25%"><img src="docs/screenshots/02-home-running.png" alt="Home screen with the VM running" width="190" /><br /><sub><b>Running</b></sub></td>
    <td align="center" width="25%"><img src="docs/screenshots/03-terminal-fastfetch.png" alt="Built-in Linux terminal" width="190" /><br /><sub><b>Terminal</b></sub></td>
    <td align="center" width="25%"><img src="docs/screenshots/04-quick-settings.png" alt="Terminal Quick Settings" width="190" /><br /><sub><b>Themes &amp; fonts</b></sub></td>
  </tr>
</table>

</div>

## Ubuntu fork

This fork replaces Podroid's Alpine guest with **Ubuntu 26.04 LTS ARM64**.

The guest uses Ubuntu's native `apt` package ecosystem and `systemd` service stack. Podroid-specific QEMU, AVF, terminal, networking, VNC, audio, storage and host-bridge integrations remain available.

The Android asset is still named `alpine-rootfs.squashfs` internally. That filename is retained temporarily as an application compatibility ABI; the filesystem stored inside it is Ubuntu.

Existing Alpine overlay data is not merged into Ubuntu. On the first Ubuntu boot, Podroid archives the previous overlay under `/mnt/persist/.podroid/` and creates a clean Ubuntu overlay. Container stores on the persistent ext4 volume remain separate from that overlay.

## What you get

- **Ubuntu 26.04 LTS ARM64** as the VM guest
- **APT** with Ubuntu `main` and `universe`
- **systemd** as guest PID 1
- **Podman, Docker and LXC** pre-installed
- **A real VM** through QEMU or supported Android AVF/pKVM devices
- **In-app terminal** with live resize
- **X11 desktop** through TigerVNC with audio
- **USB passthrough**, **SSH**, **port forwarding** and guest-to-Android bridge
- **Container backup** and Android Downloads sharing

## Quick start

1. Build or install the APK.
2. Tap **Start VM**.
3. Wait for **Ready!**.
4. Open the terminal.

```sh
cat /etc/os-release
apt update
podman run --rm ubuntu:26.04 cat /etc/os-release
docker run --rm ubuntu:26.04 cat /etc/os-release
```

Expose a container through Podroid:

```sh
podroid-forward add 8080 8080 tcp
curl http://<phone-ip>:8080
podroid-forward clean
```

SSH uses the existing Podroid forwarding configuration:

```sh
ssh root@<phone-ip> -p 9922
# default password: podroid
```

## Build

```sh
git clone https://github.com/chmodmasx/Podroid-Ubuntu.git
cd Podroid-Ubuntu
./build-all.sh all
```

Build only the Ubuntu guest rootfs:

```sh
./build-all.sh rootfs
```

The generated Android asset currently remains:

```text
app/src/main/assets/alpine-rootfs.squashfs
```

Its internal `/etc/os-release` identifies Ubuntu 26.04.

## Architecture note

Podroid uses a minimal bootstrap initramfs before `switch_root`.

The bootstrap initramfs is not the user-visible guest distribution. The persistent guest userspace after `switch_root` is Ubuntu 26.04 LTS.

## Upstream

This repository is based on [ExTV/Podroid](https://github.com/ExTV/Podroid).

Keep upstream bug reports separate when a problem only affects this Ubuntu conversion.

## Credits

| | |
|---|---|
| [Podroid](https://github.com/ExTV/Podroid) | Original Android VM project |
| [Ubuntu](https://ubuntu.com/) | Guest distribution |
| [QEMU](https://www.qemu.org) | Machine emulation |
| [Termux](https://github.com/termux/termux-app) | Terminal emulator engine |

## License

[GPLv2](LICENSE).
