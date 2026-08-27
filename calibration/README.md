# Calibration

LeRobot reads these from `~/.cache/huggingface/lerobot/calibration/`. To install:

```bash
cp -r calibration/robots         ~/.cache/huggingface/lerobot/calibration/
cp -r calibration/teleoperators  ~/.cache/huggingface/lerobot/calibration/
```

| File | Device | `--robot.id` / `--teleop.id` |
|---|---|---|
| `robots/seeed_b601_rs_follower/follower1.json` | B601-RS follower (RobStride over CAN) | `follower1` |
| `teleoperators/rebot_arm_102_leader/rebot_arm_102_leader.json` | reBot 102 leader (serial) | `rebot_arm_102_leader` |

Both list the seven joints in order: `shoulder_pan`, `shoulder_lift`,
`elbow_flex`, `wrist_flex`, `wrist_yaw`, `wrist_roll`, `gripper`. Motor ids are
1..7 on the follower (matching its CAN send ids `0x01`..`0x07`) and 0..6 on the
leader.

## These files do NOT contain the arm's zero position

Every entry is `homing_offset: 0`, `range_min: -90`, `range_max: 90` — the
placeholder values `SeeedB601FollowerBase.calibrate()` writes verbatim:

```python
logger.info("Setting range: -90° to +90° by default for all joints")
self.calibration[motor_name] = MotorCalibration(
    id=send_id, drive_mode=0, homing_offset=0, range_min=-90, range_max=90,
)
```

The real calibration is `motor.set_zero_position()`, which writes into each
RobStride motor's **non-volatile memory**, not into this file. What is committed
here only tells LeRobot that a calibration exists, so it does not prompt to
re-run one on connect.

So copying these onto another machine **does not transfer the arm's zeros**. On
new hardware you still have to run the physical procedure: move the arm to its
zero pose by hand, then let `calibrate()` call `set_zero_position()` on every
motor.

The soft `-90..90` range here is also not what actually bounds motion — that
comes from `joint_limits` in the robot config (e.g. `shoulder_lift` `0..170`,
`gripper` `0..270`), which is what `send_action` clips against.

Recorded at the calibration in effect for the `rebot_b601_rs_brown_sugar`
dataset (files last written 2026-08-12, before that collection run).
