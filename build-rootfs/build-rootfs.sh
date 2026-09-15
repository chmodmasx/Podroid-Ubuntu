#!/bin/sh
set -eu

# Run inside the Ubuntu ARM64 rootfs-builder stage.
: "${SYSTEM_VERSION:=0}"
: "${UBUNTU_VERSION:=26.04}"

# ── Accounts and privilege defaults ──────────────────────────────────────────
echo 'root:podroid' | chpasswd

groupadd -f wheel
mkdir -p /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

if command -v setcap >/dev/null 2>&1; then
    setcap cap_setuid+ep /usr/bin/newuidmap 2>/dev/null || true
    setcap cap_setgid+ep /usr/bin/newgidmap 2>/dev/null || true
fi
chmod u+s /usr/bin/sudo 2>/dev/null || true

printf 'hvc0\nttyAMA0\n' >> /etc/securetty 2>/dev/null || true

# Preserve Podroid's historical binary paths where Ubuntu differs.
if [ -x /usr/bin/Xtigervnc ] && [ ! -e /usr/bin/Xvnc ]; then
    ln -s Xtigervnc /usr/bin/Xvnc
fi
if [ ! -e /sbin/getty ] && [ -x /sbin/agetty ]; then
    ln -s agetty /sbin/getty
fi
mkdir -p /usr/share/udhcpc
if [ -f /etc/udhcpc/default.script ]; then
    ln -sf /etc/udhcpc/default.script /usr/share/udhcpc/default.script
fi

# ── Persistent container-storage mount points ────────────────────────────────
mkdir -p /var/lib/containers/storage \
         /run/containers/storage \
         /run/libpod \
         /run/crun \
         /var/lib/docker \
         /var/lib/lxc

# ── Podroid executables ──────────────────────────────────────────────────────
mkdir -p /usr/local/bin /usr/local/lib/podroid/services
for bin in podroid-resize podroid-login podroid-getty podroid-backup podroid-update-stats; do
    cp "/work/files/usr/local/bin/$bin" "/usr/local/bin/$bin"
done
chmod +x /usr/local/bin/podroid-*
chmod +x /usr/local/bin/podroid-vsock-agent 2>/dev/null || true
chmod +x /usr/local/bin/podroid-hostd 2>/dev/null || true
chmod +x /usr/local/bin/podroid-overlay-normalize 2>/dev/null || true

ln -sf podroid-hostd /usr/local/bin/podroid-notify
ln -sf podroid-hostd /usr/local/bin/podroid-forward
ln -sf podroid-hostd /usr/local/bin/podroid-open
ln -sf podroid-hostd /usr/local/bin/podroid-power
ln -sf podroid-hostd /usr/local/bin/podroid-headless
ln -sf podroid-hostd /usr/local/bin/podroid-server

# Reuse existing shell bodies only for one-shot bootstrap operations.
# systemd owns process supervision. OpenRC is not installed.
for svc in podroid-migrate podroid-bootstrap podroid-network podroid-ready; do
    cp "/work/files/etc/init.d/$svc" "/usr/local/lib/podroid/services/$svc"
    chmod 0755 "/usr/local/lib/podroid/services/$svc"
done
sed -i 's/dropbear Xvnc pulseaudio/dropbear Xvnc Xtigervnc pulseaudio/' \
    /usr/local/lib/podroid/services/podroid-ready

mkdir -p /usr/local/lib/podroid
cp /work/files/usr/local/lib/podroid/service-runner /usr/local/lib/podroid/service-runner
chmod 0755 /usr/local/lib/podroid/service-runner

# ── Podroid configuration ────────────────────────────────────────────────────
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

# ── Identity and login banner ────────────────────────────────────────────────
# Docker/BuildKit bind-mounts /etc/hostname, /etc/hosts and /etc/resolv.conf
# during RUN steps. Their guest copies are written later by the native packer
# stage so the values are both writable and actually persisted in SquashFS.
cat > /etc/issue <<'EOF'
Welcome to Podroid (Ubuntu 26.04 LTS)
Kernel \r on \m (\l)

  Default login:  root  /  podroid
  Change root password:    passwd
  Create a regular user:   adduser <name>
                           usermod -aG wheel <name>
                           (wheel group -> can run sudo)

EOF

# ── LXC defaults ─────────────────────────────────────────────────────────────
if [ -f /etc/default/lxc-net ]; then
    if grep -q '^USE_LXC_BRIDGE=' /etc/default/lxc-net; then
        sed -i 's/^USE_LXC_BRIDGE=.*/USE_LXC_BRIDGE="true"/' /etc/default/lxc-net
    else
        printf '\nUSE_LXC_BRIDGE="true"\n' >> /etc/default/lxc-net
    fi
fi

# ── systemd service graph ────────────────────────────────────────────────────
mkdir -p /etc/systemd/system
cp -a /work/files/etc/systemd/system/. /etc/systemd/system/

# Native Ubuntu daemons must wait for Podroid's mounts and network.
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

# Podroid configures networking itself. Do not replace /etc/resolv.conf here:
# Docker/BuildKit bind-mounts it in RUN steps, so unlinking it returns EBUSY.
# Dockerfile.rootfs writes the guest resolver later from the native packer stage.
ln -sf /dev/null /etc/systemd/system/systemd-networkd.service
ln -sf /dev/null /etc/systemd/system/systemd-networkd.socket
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-resolved.service

# Prevent systemd-getty-generator from consuming Podroid's serial boot channel.
ln -sf /dev/null /etc/systemd/system/serial-getty@ttyAMA0.service
ln -sf /dev/null /etc/systemd/system/serial-getty@hvc0.service
ln -sf /dev/null /etc/systemd/system/getty@hvc0.service

# Disable background package jobs inside the phone VM.
ln -sf /dev/null /etc/systemd/system/apt-daily.service
ln -sf /dev/null /etc/systemd/system/apt-daily.timer
ln -sf /dev/null /etc/systemd/system/apt-daily-upgrade.service
ln -sf /dev/null /etc/systemd/system/apt-daily-upgrade.timer

# Enable only the Podroid aggregate target explicitly.
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf ../podroid.target /etc/systemd/system/multi-user.target.wants/podroid.target

# Generate a unique machine-id on each installed VM.
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id

# Reduce immutable squashfs size. Runtime apt remains functional.
rm -rf /usr/share/man /usr/share/doc /usr/share/info \
       /var/cache/apt/archives/* /var/lib/apt/lists/*
