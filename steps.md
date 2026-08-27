conda activate rs

# check CAN number 

for c in /sys/class/net/can*; do
  echo "$(basename "$c") -> $(readlink -f "$c/device")"
done

can4 -> /sys/devices/platform/bus@0/a80aa10000.usb/usb1/1-4/1-4.1/1-4.1.4/1-4.1.4:1.0 - like this one

find leader arm port (usually /dev/ttyUSB0)

lerobot-find-port 

disconnect the leader arm and press enter
You will get the port 

connect it back again

sudo ip link set can0 down 2>/dev/null
sudo ip link set can0 type can bitrate 1000000 restart-ms 100
sudo ip link set can0 up

Calibrate follower

lerobot-calibrate \
    --robot.type=seeed_b601_rs_follower \
    --robot.port=can0 \
    --robot.id=follower1 \
    --robot.can_adapter=socketcan

    press "c" and then enter and enter again


calibrate leader arm 

sudo chmod 666 /dev/ttyUSB0

lerobot-calibrate \
    --teleop.type=rebot_arm_102_leader \
    --teleop.port=/dev/ttyUSB0 \
    --teleop.id=rebot_arm_102_leader

    Run teleoreration 

    lerobot-teleoperate \
    --robot.type=seeed_b601_rs_follower \
    --robot.port=can0 \
    --robot.id=follower1 \
    --robot.can_adapter=socketcan \
    --teleop.type=rebot_arm_102_leader \
    --teleop.port=/dev/ttyUSB0 \
    --teleop.id=rebot_arm_102_leader


    OR 
change ports in file and run this
    /home/seeed_pk/Documents/rs/helpful_docs/toggle_teleop.sh



https://wiki.seeedstudio.com/rebot_arm_b601_rs_lerobot/