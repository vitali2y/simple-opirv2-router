# Simple home WiFi/wired router @ Orange Pi RV2 SBC

Fast and simple way to make your [Orange Pi RV2](http://www.orangepi.org/orangepiwiki/index.php/Orange_Pi_RV2) SBC device as a home WiFi and wired router running on [Irradium OS](https://irradium.org/) (based on `CRUX` distribution), in few steps.

## Installation

1. Download and unpack `Irradium OS`:
   ```shell
   wget --no-check-certificate https://dl.irradium.org/irradium/images/orange_pi_rv2/irradium-3.8-riscv64-core-orange_pi_rv2-6.17.6-build-20251102.img.zst
   zstd -d irradium-3.8-riscv64-core-orange_pi_rv2-6.17.6-build-20251102.img.zst   
   ```

1. Download Irradium kernel and firmware:
   ```shell
   wget --no-check-certificate 'https://dl.irradium.org/irradium/images/orange_pi_rv2/kernel/kernel-firmware-k1#6.17.9-1.pkg.tar.gz'
   wget --no-check-certificate 'https://dl.irradium.org/irradium/images/orange_pi_rv2/kernel/kernel-k1#6.17.9-1.pkg.tar.gz'
   ```

1. Prepare image in single command:
   ```shell
   ./build.sh
   ```

   Alternatively, you can customize your SSID and WiFi password as:
   ```shell
   WIFI_SSID="MyRouter" WIFI_PASSWORD="SuperSecret!" ./build.sh
   ```

1. Format 16GB+ SD Card and burn image produced above:
   ```shell
   ➜ mintstick -m format && mintstick -m iso && sync
   ```

1. Insert SD Card into SBC.

   Connect host's (LAN) cable to router's `end1` (left from top) port.

   Connect Internet (WAN) cable to another router's `end0` (right from top) port.

   Power on.

   Done!


## License

MIT license ([LICENSE](https://github.com/vitali2y/simple-opirv2-router/blob/main/LICENSE) or <http://opensource.org/licenses/MIT>)
