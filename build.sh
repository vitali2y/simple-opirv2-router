#!/bin/bash

#
# Preparing Irradium OS image for running Orange Pi RV2 SBC as a minimal home wired/WiFi router
#
# Usage:
# * with default SSID/password as:
#   ./build.sh
# * with custom SSID/password as:
#   WIFI_SSID="MyRouter" WIFI_PASSWORD="SuperSecret!" ./build.sh
#

set -e

# configuration
VER=0.6.0
WIFI_SSID="${WIFI_SSID:-opi}"
WIFI_PASSWORD="${WIFI_PASSWORD:-$(dd if=/dev/urandom bs=12 count=1 2>/dev/null | base64 | cut -c1-12)}"
IMG_NAME="irradium-opi-router.img"
ROOT_MNT="/mnt/irradium-root"

echo "Building Orange Pi RV2 WiFi/wired router (v$VER)..."

# ensure prerequisites
command -v wget >/dev/null || { echo "wget required"; exit 1; }
command -v zstd >/dev/null || { echo "zstd required"; exit 1; }
command -v losetup >/dev/null || { echo "losetup required"; exit 1; }

# check binaries
REQUIRED_BINS=("busybox" "iw" "hostapd" "dnsmasq" "powerkey")
for bin in "${REQUIRED_BINS[@]}"; do
  if [ ! -f "utils/$bin" ]; then
    echo "Not found required binary '$bin' in 'utils' dir!"
    exit 1
  fi
done

# managing distro/kernel/firmware
mkdir -p distribs && cd distribs >/dev/null

# download kernel/firmware
REQUIRED_PKGS=("kernel-k1#6.17.9-1.pkg.tar.gz" "kernel-firmware-k1#6.17.9-1.pkg.tar.gz")
for pkg in "${REQUIRED_PKGS[@]}"; do
  if [ ! -f "$pkg" ]; then
    echo "Downloading $pkg..."
    wget --quiet --no-check-certificate \
      "https://dl.irradium.org/irradium/images/orange_pi_rv2/kernel/$pkg"
  fi
done

# download base image if missing
BASE_IMG="irradium-3.8-riscv64-core-orange_pi_rv2-6.17.6-build-20251102.img"
if [ ! -f "$BASE_IMG.zst" ]; then
  echo "Downloading Irradium OS image..."
  wget --quiet --no-check-certificate \
    https://dl.irradium.org/irradium/images/orange_pi_rv2/"$BASE_IMG.zst"
fi

cd - >/dev/null

echo "Preparing image..."
rm $IMG_NAME 2>/dev/null || true
zstd -d "distribs/$BASE_IMG.zst" -o $IMG_NAME 2>/dev/null

# create output image
LOOP_DEV=$(sudo losetup --find --show --partscan "$IMG_NAME")
sudo partprobe "$LOOP_DEV"
sleep 2

# mount root partition
ROOT_PART="${LOOP_DEV}p2"
sudo mkdir -p "$ROOT_MNT"
sudo mount "$ROOT_PART" "$ROOT_MNT"
trap 'sudo umount "$ROOT_MNT" 2>/dev/null; sudo losetup -d "$LOOP_DEV" 2>/dev/null; rmdir "$ROOT_MNT" 2>/dev/null' EXIT

# install kernel & firmware
echo "Installing kernel and firmware..."
for pkg in "${REQUIRED_PKGS[@]}"; do
  sudo tar -xf "distribs/$pkg" -C "$ROOT_MNT" --exclude=.[^/]*
done

echo "Embedding prebuilt utils..."
sudo cp ./utils/{busybox,iw,hostapd,dnsmasq,powerkey} "$ROOT_MNT/usr/local/bin/"
sudo chmod +x "$ROOT_MNT/usr/local/bin/"{busybox,iw,hostapd,dnsmasq,powerkey}
sudo ln -sf busybox "$ROOT_MNT/usr/local/bin/udhcpc"
sudo chmod +x "$ROOT_MNT/usr/local/bin/udhcpc"
sudo mkdir -p "$ROOT_MNT/var/lib/misc"

# install Armbian's generic BCM43455 NVRAM for Allwinner
echo "Installing Armbian BCM43455 NVRAM for Allwinner..."
NVRAM_FILE="brcmfmac43455-sdio.txt"
NVRAM_URL="https://raw.githubusercontent.com/armbian/firmware/refs/heads/master/brcm/$NVRAM_FILE"
NVRAM_DEST="$ROOT_MNT/lib/firmware/brcm"

mkdir -p firmware && cd firmware >/dev/null

# download firmware if missing
if [ ! -f "$NVRAM_FILE" ]; then
  echo "Downloading firmware..."
  wget --quiet --no-check-certificate "$NVRAM_URL"
fi

sudo cp $NVRAM_FILE $NVRAM_DEST

cd - >/dev/null

# append time-sync logic
sudo tee "$ROOT_MNT/etc/rc.local" <<'EOF' >/dev/null

# Sync system time early in boot
if rdate -s time.nist.gov; then
  echo "System clock updated"
else
  rdate -s pool.ntp.org 2>/dev/null && echo "Fallback time sync succeeded"
fi
EOF

# inject SSH authorized key
echo "Setting up SSH access..."
sudo mkdir -p "$ROOT_MNT/root/.ssh"
USER=$(env | grep LOGNAME | cut -d'=' -f2)
if [ -f /home/$USER/.ssh/id_rsa.pub ]; then
  sudo cp /home/$USER/.ssh/id_rsa.pub "$ROOT_MNT/root/.ssh/authorized_keys"
elif [ -f /home/$USER/.ssh/id_ed25519.pub ]; then
  sudo cp /home/$USER/.ssh/id_ed25519.pub "$ROOT_MNT/root/.ssh/authorized_keys"
else
  echo "WARNING: No SSH public key found - you won't be able to SSH in!"
  sudo touch "$ROOT_MNT/root/.ssh/authorized_keys"
fi
sudo chmod 700 "$ROOT_MNT/root/.ssh"
sudo chmod 600 "$ROOT_MNT/root/.ssh/authorized_keys"

# generate strong SSH host keys (ed25519 + rsa)
echo "Generating SSH host keys..."
sudo ssh-keygen -t ed25519 -f "$ROOT_MNT/etc/ssh/ssh_host_ed25519_key" -N "" -q
sudo ssh-keygen -t rsa -b 4096 -f "$ROOT_MNT/etc/ssh/ssh_host_rsa_key" -N "" -q
sudo chmod 600 "$ROOT_MNT/etc/ssh/ssh_host_"*"_key"
sudo chmod 644 "$ROOT_MNT/etc/ssh/ssh_host_"*"_key.pub"

sudo tee "$ROOT_MNT/etc/ssh/sshd_config" <<'EOF' >/dev/null
# Protocol
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Authentication
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no

# Security
UsePAM yes
PrintMotd no
PrintLastLog no
TCPKeepAlive no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no
PermitTunnel no
PermitUserEnvironment no
Compression no
ClientAliveInterval 300
ClientAliveCountMax 2

# Logging
LogLevel VERBOSE

# Subsystem
Subsystem sftp internal-sftp
EOF

# set fallback DNS
echo "nameserver 8.8.8.8" | sudo tee "$ROOT_MNT/etc/resolv.conf" > /dev/null

# udhcpc script (with onlink)
cat <<'EOF' | sudo tee "$ROOT_MNT/etc/udhcpc.script" >/dev/null
#!/bin/sh
case "$1" in
  bound|renew)
    ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.255}"
    ip route replace default via "$router" dev "$interface" onlink
    echo "nameserver $dns" > /etc/resolv.conf
    ;;
  deconfig)
    ifconfig "$interface" 0.0.0.0
    ip route flush dev "$interface" 2>/dev/null
    ;;
esac
EOF
sudo chmod +x "$ROOT_MNT/etc/udhcpc.script"

# composing WiFi AP script
cat <<'EOF' | sudo tee "$ROOT_MNT/usr/local/bin/wifi-ap" >/dev/null
#!/bin/sh
case "$1" in
  start)
    echo "wifi-ap: loading brcmfmac..."
    modprobe brcmfmac
    sleep 10

    # Wait for wlan0
    for i in $(seq 1 25); do
      if ip link show wlan0 >/dev/null 2>&1; then
        echo "wifi-ap: wlan0 detected"
        ip link set wlan0 up
        ip link set wlan0 master br0
        break
      fi
      sleep 2
    done

    if ! ip link show wlan0 >/dev/null 2>&1; then
      echo "ERROR: wlan0 never appeared!" >&2
      exit 1
    fi

    # Start AP
    echo "wifi-ap: starting hostapd..."
    /usr/local/bin/hostapd -B /etc/hostapd.conf >/dev/null 2>&1

    # Start DHCP on bridge
    echo "wifi-ap: starting dnsmasq on br0..."
    /usr/local/bin/dnsmasq \
        --interface=br0 \
        --listen-address=192.168.10.1 \
        --bind-interfaces \
        --dhcp-range=192.168.10.50,192.168.10.150,12h \
        --dhcp-leasefile=/run/misc/dnsmasq.leases \
        --dhcp-option=3,192.168.10.1 \
        --dhcp-option=6,192.168.10.1 \
        --no-daemon \
        --log-queries 2>/dev/null &

    echo "wifi-ap: ready"
    ;;
  stop)
    killall hostapd dnsmasq 2>/dev/null || true
    ip link set wlan0 nomaster 2>/dev/null || true
    ip link set wlan0 down 2>/dev/null || true
    ;;
esac
EOF
sudo chmod +x "$ROOT_MNT/usr/local/bin/wifi-ap"

cat <<'EOF' | sudo tee "$ROOT_MNT/etc/rc.d/wifi" >/dev/null
#!/bin/sh
start() {
  # Wait for SDIO and load driver
  timeout=0
  while [ $timeout -lt 60 ]; do
    if ls /sys/bus/sdio/devices/ 2>/dev/null | grep -q "mmc"; then
      echo "wifi: SDIO detected, loading brcmfmac..."
      modprobe brcmfmac 2>/dev/null || true
      break
    fi
    sleep 2
    timeout=$((timeout + 2))
  done

  # Wait for wlan0
  timeout=0
  while [ $timeout -lt 30 ]; do
    if ip link show wlan0 >/dev/null 2>&1; then
      echo "wifi: wlan0 ready, starting AP"
      /usr/local/bin/wifi-ap start
      return 0
    fi
    sleep 2
    timeout=$((timeout + 2))
  done
  echo "wifi: timeout" >&2
}
stop() {
  killall hostapd dnsmasq 2>/dev/null
}
case "$1" in start) start ;; stop) stop ;; restart) stop; sleep 2; start ;; *) echo "Usage: "$0" {start|stop|restart}" ;; esac
EOF
sudo chmod +x "$ROOT_MNT/etc/rc.d/wifi"

# network service
cat <<'EOF' | sudo tee "$ROOT_MNT/etc/rc.d/net" >/dev/null
#!/bin/sh
start() {
  # Loopback
  ip addr add 127.0.0.1/8 dev lo 2>/dev/null
  ip link set lo up

  # Bridge with STP off and zero forward delay
  ip link add name br0 type bridge stp_state 0 forward_delay 0
  ip link set eth1 master br0
  ip addr add 192.168.10.1/24 dev br0
  ip link set br0 up
  ip link set eth1 up

  # WAN (eth0)
  ip link set eth0 up
  sleep 2
  /usr/local/bin/udhcpc -i eth0 -s /etc/udhcpc.script -O router -O dns -t 3 -T 5 -A 3 >/dev/null 2>&1 &

  # Enable forwarding
  echo 1 > /proc/sys/net/ipv4/ip_forward

  # nftables: filter + NAT
  nft add table inet filter 2>/dev/null || true
  nft flush table inet filter

  # Input filter: only allow SSH from LAN, block everything from WAN
  # Create an 'input' chain that inspects packets destined TO the router itself
  nft add chain inet filter input '{ type filter hook input priority 0; policy drop; }'

  # Allow packets that are part of an already established or related connection (e.g., replies to outbound DNS/HTTP)
  nft add rule inet filter input ct state established,related accept

  # Allow all traffic on the loopback interface (required for local services)
  nft add rule inet filter input iifname "lo" accept

  nft add rule inet filter input iifname "br0" udp dport {67,53} accept
  nft add rule inet filter input iifname "br0" tcp dport 22 accept

  # Forward chain
  nft add chain inet filter forward '{ type filter hook forward priority 0; policy drop; }'
  nft add rule inet filter forward ct state established,related accept
  nft add rule inet filter forward iifname "br0" oifname "br0" accept
  nft add rule inet filter forward iifname "br0" oifname "eth0" accept
  nft add rule inet filter forward iifname "eth0" oifname "br0" ct state established,related accept

  # Masquerade
  nft add table ip nat 2>/dev/null || true
  nft flush table ip nat
  nft add chain ip nat postrouting '{ type nat hook postrouting priority 100; }'
  nft add rule ip nat postrouting oifname "eth0" masquerade

  echo "Network started"
}
stop() {
  killall udhcpc hostapd dnsmasq wifi-ap 2>/dev/null || true
  ip link set eth0 down 2>/dev/null
  ip link set eth1 nomaster 2>/dev/null || true
  ip link set wlan0 nomaster 2>/dev/null || true
  ip link delete br0 2>/dev/null || true

  echo "Network stopped"
}
case "$1" in start) start ;; stop) stop ;; restart) stop; sleep 2; start ;; *) echo "Usage: "$0" {start|stop|restart}" ;; esac
EOF
sudo chmod +x "$ROOT_MNT/etc/rc.d/net"

# write WiFi config
sudo tee "$ROOT_MNT/etc/hostapd.conf" <<EOF >/dev/null
interface=wlan0
bridge=br0
ssid=$WIFI_SSID
hw_mode=g
channel=6
auth_algs=1
wpa=2
wpa_passphrase=$WIFI_PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
ap_isolate=0
wpa_disable_eapol_key_retries=0
EOF

# shutdown upon short press on power on/off button
cat <<'EOF' | sudo tee "$ROOT_MNT/etc/rc.d/powerkey" >/dev/null
#!/bin/sh
# Init script for powerkey daemon
case "$1" in
  start)
    echo "Starting powerkey daemon..."
    /usr/local/bin/powerkey &
    echo "Powerkey started"
    ;;
  stop)
    echo "Stopping powerkey daemon..."
    killall powerkey 2>/dev/null || true
    echo "Powerkey stopped"
    ;;
  *)
    echo "Usage: "$0" {start|stop}"
    exit 1
esac
exit 0
EOF
sudo chmod +x "$ROOT_MNT/etc/rc.d/powerkey"

# adding wifi + powerkey services
sudo sed -i '/^SERVICES=/ s/)$/ wifi powerkey)/' "$ROOT_MNT/etc/rc.conf"

# set valid root password to bypass PAM first-login enforcement
DAYS_SINCE_EPOCH=$(( $(date +%s) / 86400 ))

# generate random password and hash
ROOT_PASS="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64 | tr -d '+/=' | cut -c1-16)"
PASS_HASH=$(openssl passwd -6 "$ROOT_PASS")

# update /etc/shadow with proper fields
sudo sed -i "s|^root:[^:]*:.*|root:$PASS_HASH:$DAYS_SINCE_EPOCH:0:99999:7:::|" "$ROOT_MNT/etc/shadow"

# enable passwordless root auto-login on ttyS0
sudo sed -i 's|^s1:2:respawn:/sbin/agetty.*ttyS0.*|s1:2:respawn:/sbin/agetty -a root 115200 ttyS0 vt100|' "$ROOT_MNT/etc/inittab"

# read-only root + volatile runtime dirs
sudo tee "$ROOT_MNT/etc/fstab" <<'EOF' >/dev/null
/dev/mmcblk0p2  /       ext4    ro,errors=remount-ro  0 1
tmpfs           /tmp    tmpfs   defaults,noatime      0 0
tmpfs           /run    tmpfs   defaults,noatime      0 0
tmpfs           /var/log tmpfs  defaults,noatime      0 0
EOF

# early boot script creates runtime dirs and enforces ro root
sudo tee "$ROOT_MNT/etc/rc.d/00-early-setup" <<'EOF' >/dev/null
#!/bin/sh
case "$1" in
  start)
    # Ensure /run is available (should be mounted via fstab)
    mkdir -p /run/resolv /run/misc
    # Remount root as read-only after early boot (e.g., rc.local time sync)
    if ! mount | grep -q "on / type.* ro,"; then
      echo "00-early-setup: Remounting root as read-only..."
      mount -o remount,ro /
      sync
    fi
    ;;
  stop)
    ;;
  *)
    echo "Usage: $0 {start|stop}"
    exit 1
    ;;
esac
EOF
sudo chmod +x "$ROOT_MNT/etc/rc.d/00-early-setup"

# update services by including 00-early-setup first, and excluding firstrun
sudo sed -i 's/^SERVICES=.*/SERVICES=(sysklogd 00-early-setup lo net sshd crond wifi powerkey)/' "$ROOT_MNT/etc/rc.conf"

# configure DNS resolution in tmpfs
sudo ln -sf /run/resolv/resolv.conf "$ROOT_MNT/etc/resolv.conf"
sudo sed -i 's|/etc/resolv.conf|/run/resolv/resolv.conf|' "$ROOT_MNT/etc/udhcpc.script"

# add rw & ro toggle scripts for debugging/maintenance
cat <<'EOF' | sudo tee "$ROOT_MNT/usr/local/bin/rw" >/dev/null
#!/bin/sh
echo "Switching root filesystem to read-write mode..."
mount -o remount,rw /
echo "Root is now read-write - remember to run 'ro' before shutdown!"
EOF

cat <<'EOF' | sudo tee "$ROOT_MNT/usr/local/bin/ro" >/dev/null
#!/bin/sh
echo "Syncing and switching root filesystem to read-only..."
sync
mount -o remount,ro /
echo "Root is now read-only!"
EOF
sudo chmod +x "$ROOT_MNT/usr/local/bin/rw" "$ROOT_MNT/usr/local/bin/ro"

echo
echo "SSID: $WIFI_SSID"
echo "WiFi password: $WIFI_PASSWORD"
echo "Gateway: 192.168.10.1"
echo "SD image: $IMG_NAME"
echo "Burn it (where <usb_sd_dev> is: /dev/sda or /dev/mmcblk0 - check carefully!) as:  sudo dd if=$IMG_NAME of=<usb_sd_dev> bs=1M && sync"
echo "or (on Linux Mint) as:  mintstick -m format && mintstick -m iso -i $IMG_NAME && sync"
echo "or balenaEtcher"
echo "Done!"
