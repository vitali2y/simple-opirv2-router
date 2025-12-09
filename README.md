# Simple home WiFi/wired router @ Orange Pi RV2 SBC

Fast and simple way to make your [Orange Pi RV2](http://www.orangepi.org/orangepiwiki/index.php/Orange_Pi_RV2) SBC device as a home WiFi and wired router running on [Irradium OS](https://irradium.org/) (based on `CRUX` distribution), in few steps.

## Installation

1. Prepare image by single command:
   ```shell
   ./build.sh
   ```

   Alternatively, you can customize your SSID and WiFi password as:
   ```shell
   WIFI_SSID="MyRouter" WIFI_PASSWORD="SuperSecret!" ./build.sh
   ```

1. Format 16GB+ SD Card and burn image generated above by next one-liner:
   ```shell
   mintstick -m format && mintstick -m iso -i irradium-opi-router.img && sync
   ```

1. Insert SD Card into SBC.

   Connect host's (LAN) cable to router's `eth1` (left from top) port.

   Connect Internet (WAN) cable to another router's `eth0` (right from top) port.

   Power on.

   Done!


## License

MIT license ([LICENSE](https://github.com/vitali2y/simple-opirv2-router/blob/main/LICENSE) or <http://opensource.org/licenses/MIT>)
