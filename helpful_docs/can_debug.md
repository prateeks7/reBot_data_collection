# CAN Debug Notes for reBotArm / RobStride on Jetson

This note summarizes the CAN debugging path used on the Jetson setup.

## Symptoms

Common failures seen:

```text
disable_all failed: control ack timeout: comm_type=4
enable_all failed: control ack timeout: comm_type=3
robstride_ping failed: ping 1 timed out
socketcan write failed: No buffer space available (os error 105)
```

Meaning: Linux can send CAN frames, but the motor is not ACKing/responding. Causes include wrong CAN interface, wrong bitrate, motor power off, wiring/termination problems, or missing USB-CAN driver.

## Check CAN Interfaces

List CAN interfaces:

```bash
ip link show type can
ip -br link
ip -details link show type can
```

Show which physical device backs each `canX`:

```bash
for c in /sys/class/net/can*; do
  echo "$(basename "$c") -> $(readlink -f "$c/device")"
done
```

Jetson onboard CAN paths look like:

```text
/sys/devices/platform/bus@0/...mttcan
```

USB-CAN paths look like:

```text
/sys/devices/...usb...
```

In our working USB-CAN case:

```text
can4 -> /sys/devices/...usb.../1-4.2.4:1.0
```

So the correct SocketCAN channel was:

```text
can4
```

## Check USB-CAN Adapter Type

List USB devices:

```bash
lsusb
lsusb -t
```

Working candleLight / gs_usb adapter:

```text
1d50:606f OpenMoko, Inc. Geschwister Schneider CAN adapter
Driver=gs_usb
```

CH340 serial adapter:

```text
1a86:7523 QinHeng Electronics CH340 serial converter
```

Important: CH340 creates `/dev/ttyUSB0`, not `canX`. The RobStride example uses SocketCAN and expects `can0`, `can4`, etc., not `/dev/ttyUSB0`.

## Check Kernel Drivers

Check loaded modules:

```bash
lsmod | grep -E 'gs_usb|peak_usb|ch341|usbserial|can'
```

Check kernel config:

```bash
zcat /proc/config.gz | grep -E 'GS_USB|CH341|USB_SERIAL'
```

If this appears:

```text
# CONFIG_CAN_GS_USB is not set
```

then `gs_usb` is not built into the running kernel/modules and must be built.

## Build gs_usb for candleLight Adapter

This was needed on Jetson kernel:

```text
6.8.12-tegra
```

Check build tree exists:

```bash
uname -r
ls /lib/modules/$(uname -r)/build
```

Build `gs_usb.ko` as an external module:

```bash
mkdir -p /tmp/gs_usb_build
cd /tmp/gs_usb_build
wget https://raw.githubusercontent.com/torvalds/linux/v6.8/drivers/net/can/usb/gs_usb.c
printf 'obj-m := gs_usb.o\n' > Makefile

make -C /lib/modules/$(uname -r)/build M=$PWD modules
ls -l /tmp/gs_usb_build/gs_usb.ko
```

Install and load:

```bash
sudo mkdir -p /lib/modules/$(uname -r)/kernel/drivers/net/can/usb
sudo cp /tmp/gs_usb_build/gs_usb.ko /lib/modules/$(uname -r)/kernel/drivers/net/can/usb/
sudo depmod -a
sudo modprobe gs_usb
```

Unplug/replug the USB-CAN adapter, then verify:

```bash
lsmod | grep gs_usb
lsusb -t
ip -br link
for c in /sys/class/net/can*; do
  echo "$(basename "$c") -> $(readlink -f "$c/device")"
done
```

Expected:

```text
Driver=gs_usb
can4 DOWN <NOARP,ECHO>
can4 -> /sys/devices/...usb...
```

Note: `lsmod` may show `gs_usb ... 0` even when `lsusb -t` says `Driver=gs_usb`; use `lsusb -t` and the `canX -> ...usb...` path as the stronger checks.

## Bring Up the USB-CAN Interface

For the working USB-backed interface, for example `can4`:

```bash
sudo ip link set can4 down
sudo ip link set can4 up type can bitrate 1000000 restart-ms 100
sudo ip link set can4 txqueuelen 1000
ip -details link show can4
```

Healthy state before testing:

```text
can state ERROR-ACTIVE
```

If the robot uses 500 kbit/s instead:

```bash
sudo ip link set can4 down
sudo ip link set can4 up type can bitrate 500000 restart-ms 100
sudo ip link set can4 txqueuelen 1000
```

## Test RobStride Motor

Test motor ID `0x01`:

```bash
motorbridge-cli run --vendor robstride --channel can4 --model rs-06 --motor-id 1 --feedback-id 0xFD --mode disable --loop 1
```

Optional scan, though RobStride may not always respond well to scan/query:

```bash
motorbridge-cli scan --vendor robstride --channel can4 --start-id 1 --end-id 10
```

The direct `run ... --mode disable` or the Python example is the better proof.

## Update Project Config

For `reBotArm_control_py/config/rebotarm_rs.yaml`:

```yaml
channel: can4
```

For `reBotArm_control_py/example/0x01rs06_test.py`:

```python
CHANNEL = "can4"
```

For LeRobot:

```bash
lerobot-calibrate --robot.type=seeed_b601_rs_follower --robot.port=can4
```

## If Using CH340 Serial Adapter

CH340 appears as:

```text
1a86:7523 QinHeng Electronics CH340 serial converter
```

Load driver:

```bash
sudo modprobe usbserial
sudo modprobe ch341
ls -l /dev/ttyUSB*
```

Expected:

```text
/dev/ttyUSB0
```

But `/dev/ttyUSB0` is not SocketCAN. This will fail in the RobStride example:

```python
CHANNEL = "/dev/ttyUSB0"
```

with an error like:

```text
if_nametoindex failed for /dev/ttyUSB0
```

Use CH340 only with software that supports its serial protocol. The RobStride SocketCAN path needs a `canX` interface.

## Listen for CAN Traffic

Install can-utils if needed:

```bash
sudo apt install can-utils
```

Listen on all CAN interfaces:

```bash
candump any
```

Power-cycle the robot while `candump` is running. If frames appear, the first column shows the interface:

```text
can4  ...
```

## Physical Checks

If all software checks look right but motor commands still timeout:

1. Confirm motor/arm main power is on.
2. Confirm CANH to CANH, CANL to CANL, and GND/common ground.
3. Confirm termination.
4. Confirm the correct bitrate, usually `1000000` or `500000`.
5. Confirm motor ID, commonly `0x01` for the first RS06.

With power off, measure resistance between CANH and CANL:

```text
~60 ohm   good: two 120 ohm terminators total
~120 ohm  only one terminator
very high no terminator or open wiring
<40 ohm   too many terminators or short
```

If the USB-CAN adapter is at the end of the bus, enable its 120 ohm termination. On the red two-switch adapter, DIP `1=ON` and `2=ON` likely enables termination.

## Quick Recovery Checklist

```bash
sudo modprobe gs_usb
lsusb -t
ip -br link
for c in /sys/class/net/can*; do
  echo "$(basename "$c") -> $(readlink -f "$c/device")"
done

sudo ip link set can4 down
sudo ip link set can4 up type can bitrate 1000000 restart-ms 100
sudo ip link set can4 txqueuelen 1000
ip -details link show can4

motorbridge-cli run --vendor robstride --channel can4 --model rs-06 --motor-id 1 --feedback-id 0xFD --mode disable --loop 1
```
