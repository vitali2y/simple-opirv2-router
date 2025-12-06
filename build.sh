#!/bin/bash

# Preparing Irradium 3.8 OS image for running Orange Pi RV2 SBC as a simple wired/WiFi router

# Usage:
# * with default SSID/password as:
#   ./build.sh
# * with custom SSID/password as:
#   WIFI_SSID="MyRouter" WIFI_PASSWORD="SuperSecret!" ./build.sh

set -e

echo "simple wired/WiFi router setup..."

# predefined mandatory local files
IMG="irradium-3.8-riscv64-core-orange_pi_rv2-6.17.6-build-20251102.img"
KERNEL_PKG="kernel-k1#6.17.9-1.pkg.tar.gz"
FW_PKG="kernel-firmware-k1#6.17.9-1.pkg.tar.gz"

WIFI_SSID="${WIFI_SSID:-OPI-RV2-Router}"
WIFI_PASSWORD="${WIFI_PASSWORD:-ChangeMe123!}"

BOOT_MNT="/mnt/opi-boot"
ROOT_MNT="/mnt/opi-root"

# check binaries
REQUIRED_BINS=("busybox" "iw" "hostapd" "dnsmasq")
for bin in "${REQUIRED_BINS[@]}"; do
  if [ ! -f "$bin" ]; then
    echo "required binary '$bin' not found!"
    exit 1
  fi
done
echo "all required binaries found"

echo "mounting Irradium image..."
LOOP=$(sudo losetup -f --show "$IMG")
sudo partprobe "$LOOP"
sudo mkdir -p "$BOOT_MNT" "$ROOT_MNT"
sudo mount "${LOOP}p1" "$BOOT_MNT"
sudo mount "${LOOP}p2" "$ROOT_MNT"

# ensure serial console is enabled for debugging
echo "ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100" sudo tee -a "$ROOT_MNT/etc/inittab"

echo "upgrading to kernel 6.17.9..."
sudo tar -xf "$KERNEL_PKG" -C "$ROOT_MNT"
sudo tar -xf "$FW_PKG" -C "$ROOT_MNT"
sudo cp "$ROOT_MNT/boot/Image" "$BOOT_MNT/"
sudo cp -r "$ROOT_MNT/boot/dtbs" "$BOOT_MNT/" 2>/dev/null || true

echo "embedding prebuilt binaries..."
sudo cp ./utils/{busybox,iw,hostapd,dnsmasq} "$ROOT_MNT/usr/local/bin/"
sudo chmod +x "$ROOT_MNT/usr/local/bin/"{busybox,iw,hostapd,dnsmasq}
sudo ln -sf busybox "$ROOT_MNT/usr/local/bin/udhcpc"
sudo chmod +x "$ROOT_MNT/usr/local/bin/udhcpc"
sudo mkdir -p "$ROOT_MNT/var/lib/misc"

# composing network init script
echo "network magic..."

# udhcpc default script (required for route/DNS setup)
sudo mkdir -p "$ROOT_MNT/etc/udhcpc"
cat <<'EOF' | sudo tee "$ROOT_MNT/etc/udhcpc/default.script" >/dev/null
#!/bin/sh
[ -z "$1" ] && echo "error: should be called from udhcpc" && exit 1
case "$1" in
    deconfig)
        /sbin/ifconfig $interface 0.0.0.0
        ;;
    renew|bound)
        /sbin/ifconfig $interface $ip netmask $subnet
        if [ -n "$router" ]; then
            # clear existing default routes
            while ip route del default dev $interface 2>/dev/null; do :; done
            # add new default route
            for i in $router; do
                ip route add default via $i dev $interface
            done
        fi
        echo -n > /etc/resolv.conf
        [ -n "$domain" ] && echo "search $domain" >> /etc/resolv.conf
        for i in $dns; do
            echo "nameserver $i" >> /etc/resolv.conf
        done
        ;;
esac
EOF
sudo chmod +x "$ROOT_MNT/etc/udhcpc/default.script"

cat <<'EOF' | sudo tee "$ROOT_MNT/etc/rc.d/net" >/dev/null
#!/bin/sh
case $1 in
start)
  # wait for eth0
  while ! ip link show eth0 >/dev/null 2>&1; do sleep 1; done
  ip link set eth0 up

  # get WAN IP
  if /usr/local/bin/udhcpc -t 3 -T 2 -i eth0 -s /etc/udhcpc/default.script; then
    echo "WAN: DHCP lease obtained"
  else
    /usr/local/bin/udhcpc -i eth2 -s /etc/udhcpc/default.script
  fi

  echo "nameserver 8.8.8.8" > /etc/resolv.conf

  # LAN: eth1 (static IP + DHCP)
  ip link set eth1 up
  ip addr add 192.168.10.1/24 dev eth1
  mkdir -p /var/lib/misc
  WIFI_SUBNET="${WIFI_SUBNET:-192.168.12}"
  LAN_SUBNET="${LAN_SUBNET:-192.168.10}"

  # kill any running instance
  killall dnsmasq 2>/dev/null || true

  # start with explicit binding and upstream DNS
  /usr/local/bin/dnsmasq \
    --interface=eth1 \
    --interface=wlan0 \
    --listen-address=192.168.10.1 \
    --listen-address=192.168.12.1 \
    --dhcp-range=wlan0,${WIFI_SUBNET}.50,${WIFI_SUBNET}.150,12h \
    --dhcp-range=eth1,${LAN_SUBNET}.50,${LAN_SUBNET}.150,12h \
    --dhcp-option=wlan0,option:dns-server,${WIFI_SUBNET}.1 \
    --dhcp-option=eth1,option:dns-server,${LAN_SUBNET}.1 \
    --no-resolv \
    --server=8.8.8.8 \
    --server=1.1.1.1 \
    --no-hosts \
    --bind-interfaces
#    --no-daemon \
#    --log-queries \
#    --log-facility=/var/log/dnsmasq.log

  # enable forwarding
  echo 1 > /proc/sys/net/ipv4/ip_forward
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

  # load NAT
  nft -f /etc/nftables.conf
  ;;
stop)
  killall udhcpc dnsmasq-static 2>/dev/null || true
  ip addr flush dev eth0 2>/dev/null || true
  ip addr flush dev eth1 2>/dev/null || true
  ;;
esac
EOF
sudo chmod +x "$ROOT_MNT/etc/rc.d/net"

# composing WiFi AP script
cat <<'EOF' | sudo tee "$ROOT_MNT/etc/rc.d/wifi-ap" >/dev/null
#!/bin/sh
case $1 in
start)
  modprobe brcmfmac
  sleep 5

  # wait indefinitely for wlan0 (critical for SDIO)
  while ! ip link show wlan0 >/dev/null 2>&1; do
    echo "wifi-ap: waiting for wlan0..."
    sleep 5
  done

  # configure interface
  ip link set wlan0 down 2>/dev/null || true
  sleep 2
  ip link set wlan0 up
  ip addr add 192.168.12.1/24 dev wlan0

  # kill stale processes
  killall dnsmasq hostapd 2>/dev/null || true
  sleep 2

  # start services
  /usr/local/bin/hostapd -B /etc/hostapd.conf
  /usr/local/bin/dnsmasq --interface=wlan0 --dhcp-range=192.168.12.50,192.168.12.150,12h
  ;;
stop)
  killall hostapd dnsmasq 2>/dev/null || true
  ip addr flush wlan0 2>/dev/null || true
  ;;
esac
EOF
sudo chmod +x "$ROOT_MNT/etc/rc.d/wifi-ap"

# hostapd config
cat <<EOF | sudo tee "$ROOT_MNT/etc/hostapd.conf" >/dev/null
interface=wlan0
driver=nl80211
ssid=${WIFI_SSID}
hw_mode=g
channel=6
wpa=2
wpa_passphrase=${WIFI_PASSWORD}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

# nftables NAT rules
cat <<'EOF' | sudo tee "$ROOT_MNT/etc/nftables.conf" >/dev/null
flush ruleset
table nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "eth0" masquerade
  }
}
table inet filter {
  chain forward {
    type filter hook forward priority 0;
    iifname "wlan0" oifname "eth0" accept
    iifname "eth0" oifname "wlan0" ct state related,established accept
    iifname "eth1" oifname "eth0" accept
    iifname "eth0" oifname "eth1" ct state related,established accept
  }
}
EOF

# auto-load nftables at boot
echo "nft -f /etc/nftables.conf" | sudo tee -a "$ROOT_MNT/etc/rc.d/net"

# SSH hardening
cat <<EOF | sudo tee "$ROOT_MNT/etc/ssh/sshd_config" >/dev/null
Port 22
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
TCPKeepAlive yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/ssh/sftp-server
EOF

# generate host keys
sudo chroot "$ROOT_MNT" /bin/sh -c "ssh-keygen -A" 2>/dev/null || true

# enabling services
if ! grep -q "net wifi-ap" "$ROOT_MNT/etc/rc.conf"; then
  sudo sed -i '/^SERVICES=/ s/)$/ net wifi-ap)/' "$ROOT_MNT/etc/rc.conf"
fi

# cleaning up
sync
sudo umount "$BOOT_MNT" "$ROOT_MNT"
sudo losetup -d "$LOOP"
sudo rmdir "$BOOT_MNT" "$ROOT_MNT"

echo "SSID: $WIFI_SSID"
echo "gateway: 192.168.10.1"
echo "SD image: $IMG"
echo "burn it (where <usb_sd_dev> is: /dev/sda or /dev/mmcblk0 - check carefully!) as:  sudo dd if=$IMG of=<usb_sd_dev> bs=1M && sync"
echo "or (on Linux Mint) as:  mintstick -m format && mintstick -m iso && sync"
echo "done!"
