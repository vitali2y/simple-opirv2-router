#!/bin/bash

# Preparing Irradium 3.8 OS image for running Orange Pi RV2 SBC as a simple wired/WiFi router

# Usage:
# * with default SSID/password as:
#   ./build.sh
# * with custom SSID/password as:
#   WIFI_SSID="MyRouter" WIFI_PASSWORD="SuperSecret!" ./build.sh

set -e

# configuration
WIFI_SSID="${WIFI_SSID:-opi}"
WIFI_PASSWORD="${WIFI_PASSWORD:-$(dd if=/dev/urandom bs=12 count=1 2>/dev/null | base64 | cut -c1-12)}"
IMG_NAME="irradium-opi-router.img"
ROOT_MNT="/mnt/irradium-root"

echo "Building Orange Pi RV2 router..."

# ensure prerequisites
command -v wget >/dev/null || { echo "wget required"; exit 1; }
command -v zstd >/dev/null || { echo "zstd required"; exit 1; }
command -v losetup >/dev/null || { echo "losetup required"; exit 1; }

# check binaries
REQUIRED_BINS=("busybox" "iw" "hostapd" "dnsmasq")
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
rm $IMG_NAME
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
sudo cp ./utils/{busybox,iw,hostapd,dnsmasq} "$ROOT_MNT/usr/local/bin/"
sudo chmod +x "$ROOT_MNT/usr/local/bin/"{busybox,iw,hostapd,dnsmasq}
sudo ln -sf busybox "$ROOT_MNT/usr/local/bin/udhcpc"
sudo chmod +x "$ROOT_MNT/usr/local/bin/udhcpc"
sudo mkdir -p "$ROOT_MNT/var/lib/misc"

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
        break
      fi
      sleep 2
    done

    if ! ip link show wlan0 >/dev/null 2>&1; then
      echo "ERROR: wlan0 never appeared!" >&2
      exit 1
    fi

    # Configure interface
    ip link set wlan0 up
    ip addr add 192.168.12.1/24 dev wlan0 2>/dev/null || true

    # Kill stale processes
    killall hostapd dnsmasq 2>/dev/null || true
    sleep 2

    # Start AP and DHCP (ONLY NOW)
    echo "wifi-ap: starting hostapd..."
    /usr/local/bin/hostapd -B /etc/hostapd.conf >/dev/null 2>&1

    echo "wifi-ap: starting dnsmasq..."
    /usr/local/bin/dnsmasq \
      --interface=wlan0 \
      --dhcp-range=192.168.12.50,192.168.12.150,12h \
      --no-daemon \
      --log-queries \
      >/dev/null 2>&1 &

    echo "wifi-ap: ready"
    ;;
  stop)
    killall hostapd dnsmasq 2>/dev/null || true
    ip link set wlan0 down 2>/dev/null || true
    ;;
esac
EOF
sudo chmod +x "$ROOT_MNT/usr/local/bin/wifi-ap"

# network service
cat <<'EOF' | sudo tee "$ROOT_MNT/etc/rc.d/net" >/dev/null
#!/bin/sh
start() {
  # Loopback
  ip addr add 127.0.0.1/8 dev lo 2>/dev/null
  ip link set lo up

  # LAN (eth1)
  ip addr add 192.168.10.1/24 dev eth1 2>/dev/null
  ip link set eth1 up

  # Start AP
  /usr/local/bin/wifi-ap start &

  # WAN (eth0)
  ip link set eth0 up
  sleep 2
  /usr/local/bin/udhcpc -i eth0 -s /etc/udhcpc.script -t 3 -T 5 -A 3 >/dev/null 2>&1 &

  # Enable forwarding
  echo 1 > /proc/sys/net/ipv4/ip_forward

  # nftables: filter + NAT
  nft add table inet filter 2>/dev/null || true
  nft flush table inet filter
  nft add chain inet filter forward '{ type filter hook forward priority 0; policy drop; }'
  nft add rule inet filter forward ct state established,related accept
  nft add rule inet filter forward ip saddr 192.168.10.0/24 ip daddr 192.168.12.0/24 accept
  nft add rule inet filter forward ip saddr 192.168.12.0/24 ip daddr 192.168.10.0/24 accept
  nft add rule inet filter forward ip saddr { 192.168.10.0/24, 192.168.12.0/24 } oifname "eth0" accept
  nft add rule inet filter forward ip saddr { 192.168.10.0/24, 192.168.12.0/24 } accept

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
  ip link set eth1 down 2>/dev/null
  ip link set wlan0 down 2>/dev/null

  echo "Network stopped"
}
case "$1" in start) start ;; stop) stop ;; restart) stop; sleep 2; start ;; *) echo "Usage: $0 {start|stop|restart}" ;; esac
EOF
sudo chmod +x "$ROOT_MNT/etc/rc.d/net"

# write WiFi config
sudo tee "$ROOT_MNT/etc/hostapd.conf" <<EOF >/dev/null
interface=wlan0
ssid=$WIFI_SSID
hw_mode=g
channel=6
auth_algs=1
wpa=2
wpa_passphrase=$WIFI_PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

echo "SSID: $WIFI_SSID"
echo "WiFi password: $WIFI_PASSWORD"
echo "Gateway: 192.168.10.1"
echo "SD image: $IMG_NAME"
echo "Burn it (where <usb_sd_dev> is: /dev/sda or /dev/mmcblk0 - check carefully!) as:  sudo dd if=$IMG_NAME of=<usb_sd_dev> bs=1M && sync"
echo "or (on Linux Mint) as:  mintstick -m format && mintstick -m iso -i $IMG_NAME && sync"
echo "or balenaEtcher"
echo "Done!"
