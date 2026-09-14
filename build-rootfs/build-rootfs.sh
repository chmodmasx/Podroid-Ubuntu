#!/bin/sh
set -eu

# This script runs inside the Ubuntu ARM64 rootfs-builder stage.
ROOTFS=/
: "${SYSTEM_VERSION:=0}"
: "${UBUNTU_VERSION:=26.04}"

# ── Account and privilege defaults ───────────────────────────────────────────
# Keep the historical Podroid root password for compatibility.
echo 'root:podroid' | chpasswd

# Preserve Podroid's documented wheel-group workflow on Ubuntu.
groupadd -f wheel
mkdir -p /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

# Rootless user namespaces need these helpers to retain privilege transitions.
if command -v setcap >/dev/null 2>&1; then
    setcap cap_setuid+ep /usr/bin/newuidmap 2>/dev/null || true
    setcap cap_setgid+ep /usr/bin/newgidmap 2>/dev/null || true
fi
chmod u+s /usr/bin/sudo 2>/dev/null || true

# Allow root login on both Podroid console devices.
printf 'hvc0\nttyAMA0\n' >> /etc/securetty 2>/dev/null || true

# The Debian/Ubuntu TigerVNC binary is Xtigervnc. Keep Podroid's old path ABI.
if [ -x /usr/bin/Xtigervnc ] && [ ! -e /usr/bin/Xvnc ]; then
    ln -s Xtigervnc /usr/bin/Xvnc
fi

# Debian's udhcpc helper lives here. Keep BusyBox's conventional path available.
mkdir -p /usr/share/udhcpc
if [ -f /etc/udhcpc/default.script ]; then
    ln -sf /etc/udhcpc/default.script /usr/share/udhcpc/default.script
fi

# ── Persistent container-storage preparation ─────────────────────────────────
mkdir -p /var/lib/containers/storage \
         /run/containers/storage \
         /run/libpod \
         /run/crun \
         /var/lib/docker \
         /var/lib/lxc

# ── Podroid executables and configuration ────────────────────────────────────
mkdir -p /usr/local/bin /usr/local/lib/podroid/services
cp /work/files/usr/local/bin/podroid-resize /usr/local/bin/
cp /work/files/usr/local/bin/podroid-login /usr/local/bin/
cp /work/files/usr/local/bin/podroid-getty /usr/local/bin/
cp /work/files/usr/local/bin/podroid-backup /usr/local/bin/
cp /work/files/usr/local/bin/podroid-update-stats /usr/local/bin/
chmod +x /usr/local/bin/podroid-*

# Native helpers were copied by Dockerfile.rootfs before this script runs.
chmod +x /usr/local/bin/podroid-vsock-agent 2>/dev/null || true
chmod +x /usr/local/bin/podroid-hostd 2>/dev/null || true
chmod +x /usr/local/bin/podroid-overlay-normalize 2>/dev/null || true
ln -sf podroid-hostd /usr/local/bin/podroid-notify
ln -sf podroid-hostd /usr/local/bin/podroid-forward
ln -sf podroid-hostd /usr/local/bin/podroid-open
ln -sf podroid-hostd /usr/local/bin/podroid-power
ln -sf podroid-hostd /usr/local/bin/podroid-headless
ln -sf podroid-hostd /usr/local/bin/podroid-server

# Reuse the battle-tested service bodies for one-shot bootstrap operations.
# systemd owns process supervision; OpenRC itself is not installed.
for svc in podroid-migrate podroid-bootstrap podroid-network podroid-ready; do
    cp "/work/files/etc/init.d/$svc" "/usr/local/lib/podroid/services/$svc"
    chmod 0755 "/usr/local/lib/podroid/services/$svc"
done
# Ubuntu names TigerVNC's process Xtigervnc.
sed -i 's/dropbear Xvnc pulseaudio/dropbear Xvnc Xtigervnc pulseaudio/' \
    /usr/local/lib/podroid/services/podroid-ready

mkdir -p /etc/podroid/migrations
cp /work/files/etc/podroid/forwards.conf /etc/podroid/forwards.conf
cp /work/files/etc/podroid/migrations/README /etc/podroid/migrations/README
printf '%s\n' "$SYSTEM_VERSION" > /etc/podroid/system-version
printf 'ubuntu-%s\n' "$UBUNTU_VERSION" > /etc/podroid/rootfs-id
chmod 0644 /etc/podroid/forwards.conf /etc/podroid/system-version /etc/podroid/rootfs-id

mkdir -p /etc/profile.d
cp /work/files/etc/profile.d/podroid-color.sh /etc/profile.d/
cp /work/files/etc/profile.d/podroid-x11.sh /etc/profile.d/
chmod 0644 /etc/profile.d/podroid-color.sh /etc/profile.d/podroid-x11.sh

mkdir -p /etc/containers
cp /work/files/etc/containers/storage.conf /etc/containers/storage.conf
cat > /etc/containers/containers.conf <<'EOF'
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
EOF

# ── Host identity and login banner ───────────────────────────────────────────
printf 'podroid\n' > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost podroid
::1 localhost ip6-localhost
EOF
cat > /etc/issue <<'EOF'
Welcome to Podroid (Ubuntu 26.04 LTS)
Kernel \r on \m (\l)

  Default login:  root  /  podroid
  Change root password:    passwd
  Create a regular user:   adduser <name>
                           usermod -aG wheel <name>
                           (wheel group -> can run sudo)

EOF

# LXC ships its native systemd units on Ubuntu. Enable its bridge explicitly.
if [ -f /etc/default/lxc-net ]; then
    if grep -q '^USE_LXC_BRIDGE=' /etc/default/lxc-net; then
        sed -i 's/^USE_LXC_BRIDGE=.*/USE_LXC_BRIDGE="true"/' /etc/default/lxc-net
    else
        printf '\nUSE_LXC_BRIDGE="true"\n' >> /etc/default/lxc-net
    fi
fi

# ── Small compatibility runner for one-shot OpenRC-style service bodies ─────
cat > /usr/local/lib/podroid/service-runner <<'EOF'
#!/bin/sh
set -u
SERVICE=${1:?service path required}
ACTION=${2:-start}

ebegin() { printf ' * %s\n' "$*"; }
einfo()  { printf ' * %s\n' "$*"; }
ewarn()  { printf ' * WARNING: %s\n' "$*" >&2; }
eerror() { printf ' * ERROR: %s\n' "$*" >&2; }
eend() {
    _rc=${1:-0}
    shift 2>/dev/null || true
    if [ "$_rc" -ne 0 ]; then
        ewarn "${*:-service failed}"
    fi
    return "$_rc"
}
mark_service_inactive() { return 0; }

# shellcheck disable=SC1090
. "$SERVICE"
case "$ACTION" in
    start)
        if command -v start >/dev/null 2>&1; then start; fi
        ;;
    stop)
        if command -v stop >/dev/null 2>&1; then stop; fi
        ;;
    *)
        echo "unsupported action: $ACTION" >&2
        exit 2
        ;;
esac
EOF
chmod 0755 /usr/local/lib/podroid/service-runner

# ── Native systemd service graph ─────────────────────────────────────────────
mkdir -p /etc/systemd/system

cat > /etc/systemd/system/podroid-migrate.service <<'EOF'
[Unit]
Description=Podroid system migrations
After=local-fs.target
Before=podroid-bootstrap.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/podroid/service-runner /usr/local/lib/podroid/services/podroid-migrate start
RemainAfterExit=yes
EOF

cat > /etc/systemd/system/podroid-bootstrap.service <<'EOF'
[Unit]
Description=Podroid VM bootstrap
Requires=podroid-migrate.service
After=podroid-migrate.service local-fs.target
Before=podroid-network.service docker.service lxc-net.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/podroid/service-runner /usr/local/lib/podroid/services/podroid-bootstrap start
RemainAfterExit=yes
EOF

cat > /etc/systemd/system/podroid-network.service <<'EOF'
[Unit]
Description=Podroid VM networking
Requires=podroid-bootstrap.service
After=podroid-bootstrap.service
Before=network-online.target dropbear.service docker.service lxc-net.service podroid-ready.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/podroid/service-runner /usr/local/lib/podroid/services/podroid-network start
RemainAfterExit=yes
EOF

cat > /etc/systemd/system/podroid-resize.service <<'EOF'
[Unit]
Description=Podroid terminal resize daemon
Requires=podroid-bootstrap.service
After=podroid-bootstrap.service
Before=podroid-ready.service

[Service]
Type=simple
ExecStart=/usr/local/bin/podroid-resize
Restart=always
RestartSec=1
EOF

cat > /etc/systemd/system/podroid-hostd.service <<'EOF'
[Unit]
Description=Podroid guest to Android host bridge
Requires=podroid-bootstrap.service
After=podroid-bootstrap.service
Before=podroid-ready.service

[Service]
Type=simple
ExecStart=/usr/local/bin/podroid-hostd
Restart=on-failure
RestartSec=1
EOF

cat > /etc/systemd/system/podroid-vsock.service <<'EOF'
[Unit]
Description=Podroid AVF vsock control and forwarding agent
ConditionKernelCommandLine=podroid.backend=avf
Requires=podroid-bootstrap.service
After=podroid-bootstrap.service
Before=podroid-downloads.service podroid-ready.service

[Service]
Type=simple
ExecStart=/usr/local/bin/podroid-vsock-agent
Restart=on-failure
RestartSec=1
EOF

cat > /etc/systemd/system/podroid-downloads.service <<'EOF'
[Unit]
Description=Podroid AVF Downloads share
ConditionKernelCommandLine=podroid.backend=avf
Requires=podroid-network.service podroid-vsock.service
After=podroid-network.service podroid-vsock.service
Before=podroid-ready.service

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /mnt/downloads
ExecStart=/usr/local/bin/podroid-vsock-agent downloads-9p
ExecStop=-/bin/umount /mnt/downloads
Restart=on-failure
RestartSec=1
EOF

cat > /etc/systemd/system/podroid-xvnc.service <<'EOF'
[Unit]
Description=Podroid X11 VNC server
Requires=podroid-bootstrap.service
After=podroid-bootstrap.service podroid-network.service
Before=podroid-ready.service

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'rm -f /tmp/.X0-lock /tmp/.X11-unix/X0; mkdir -p /tmp/.X11-unix'
ExecStart=/bin/sh -c 'dpi=$(sed -n "s/.*podroid\\.x11\\.dpi=\\([0-9]*\\).*/\\1/p" /proc/cmdline); [ -n "$dpi" ] || dpi=96; exec /usr/bin/Xtigervnc :0 -geometry 1280x720 -depth 24 -SecurityTypes None -localhost no -rfbport 5900 -AlwaysShared -dpi "$dpi" -AcceptSetDesktopSize'
Restart=on-failure
RestartSec=1
OOMScoreAdjust=-1000
EOF

cat > /etc/systemd/system/podroid-pulseaudio.service <<'EOF'
[Unit]
Description=Podroid desktop audio server
Requires=podroid-bootstrap.service
After=podroid-bootstrap.service
Before=podroid-ready.service

[Service]
Type=simple
Environment=PULSE_RUNTIME_PATH=/run/podroid-pulse
Environment=XDG_RUNTIME_DIR=/run/podroid-pulse
ExecStartPre=/bin/mkdir -p /run/podroid-pulse
ExecStart=/usr/bin/pulseaudio --daemonize=no --disallow-exit --exit-idle-time=-1 --load=module-null-sink\ sink_name=podroid_sink\ rate=44100\ channels=2\ format=s16le --load=module-simple-protocol-tcp\ source=podroid_sink.monitor\ record=true\ rate=44100\ format=s16le\ channels=2\ listen=0.0.0.0\ port=4713 --load=module-native-protocol-unix
Restart=on-failure
RestartSec=1
OOMScoreAdjust=-1000
EOF

cat > /etc/systemd/system/podroid-ready.service <<'EOF'
[Unit]
Description=Podroid ready marker
Requires=podroid-network.service
After=podroid-network.service podroid-resize.service podroid-hostd.service podroid-vsock.service podroid-downloads.service podroid-xvnc.service podroid-pulseaudio.service dropbear.service docker.service lxc-net.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/podroid/service-runner /usr/local/lib/podroid/services/podroid-ready start
RemainAfterExit=yes
EOF

cat > /etc/systemd/system/podroid-getty.service <<'EOF'
[Unit]
Description=Podroid interactive console
After=podroid-ready.service
Requires=podroid-ready.service
Conflicts=getty@hvc0.service serial-getty@hvc0.service

[Service]
Type=idle
ExecStart=-/usr/local/bin/podroid-getty hvc0
Restart=always
RestartSec=0

[Install]
WantedBy=podroid.target
EOF

cat > /etc/systemd/system/podroid.target <<'EOF'
[Unit]
Description=Podroid guest services
Requires=podroid-migrate.service podroid-bootstrap.service podroid-network.service
Wants=podroid-resize.service podroid-hostd.service podroid-vsock.service podroid-downloads.service podroid-xvnc.service podroid-pulseaudio.service docker.service dropbear.service lxc-net.service podroid-ready.service podroid-getty.service
After=local-fs.target

[Install]
WantedBy=multi-user.target
EOF

# Ensure stock Ubuntu daemons wait for Podroid's raw-ext4 bind mounts/network.
mkdir -p /etc/systemd/system/docker.service.d \
         /etc/systemd/system/dropbear.service.d \
         /etc/systemd/system/lxc-net.service.d
cat > /etc/systemd/system/docker.service.d/podroid.conf <<'EOF'
[Unit]
Requires=podroid-bootstrap.service
After=podroid-bootstrap.service podroid-network.service
EOF
cat > /etc/systemd/system/dropbear.service.d/podroid.conf <<'EOF'
[Unit]
Requires=podroid-network.service
After=podroid-network.service
EOF
cat > /etc/systemd/system/lxc-net.service.d/podroid.conf <<'EOF'
[Unit]
Requires=podroid-bootstrap.service podroid-network.service
After=podroid-bootstrap.service podroid-network.service
EOF

# Podroid owns guest networking and resolv.conf.
ln -sf /dev/null /etc/systemd/system/systemd-networkd.service
ln -sf /dev/null /etc/systemd/system/systemd-networkd.socket
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-resolved.service
rm -f /etc/resolv.conf
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf

# Enable the Podroid target without requiring a running systemd during build.
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf ../podroid.target /etc/systemd/system/multi-user.target.wants/podroid.target

# Avoid stale machine identity across installations.
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id

# Reduce immutable squashfs size. Keep apt metadata configuration for runtime use.
rm -rf /usr/share/man /usr/share/doc /usr/share/info \
       /var/cache/apt/archives/* /var/lib/apt/lists/*
