#!/usr/bin/env python
"""Check the B601 motors for faults and ramp the arm to its home pose.

Standalone counterpart to the homing that `lerobot-record` and the async
`robot_client` do internally. Use it when the async client dies before it can
home, or to inspect motor state without starting any policy.

    python inference/go_home.py                 # report faults, then home
    python inference/go_home.py --check-only    # report faults, do not move
    python inference/go_home.py --clear-errors  # clear latched errors, then home
    python inference/go_home.py --can can4 --duration 5

Exit code is 1 if any motor reports a fault, so a shell script can gate on it.
"""

import argparse
import logging
import math
import sys

from lerobot.robots import make_robot_from_config
from lerobot.utils.robot_utils import _read_robot_action_pose, return_robot_to_home

JOINTS = [
    "shoulder_pan",
    "shoulder_lift",
    "elbow_flex",
    "wrist_flex",
    "wrist_yaw",
    "wrist_roll",
    "gripper",
]


def build_robot(can_iface: str, robot_id: str):
    # Importing the plugin registers the seeed_b601_rs_follower config subclass.
    from lerobot_robot_seeed_b601.config_seeed_b601_rs_follower import SeeedB601RSFollowerConfig

    # No cameras: homing only needs the motor bus, and opening RealSense here
    # would fight with whatever else holds the cameras.
    cfg = SeeedB601RSFollowerConfig(
        port=can_iface,
        id=robot_id,
        can_adapter="socketcan",
        cameras={},
    )
    return make_robot_from_config(cfg)


def report_motor_state(robot) -> bool:
    """Print per-motor status. Returns True if every motor looks healthy."""
    for motor in robot.motors.values():
        motor.request_feedback()
    robot.bus.poll_feedback_once()

    print(f"\n{'joint':<15} {'pos °':>9} {'vel':>8} {'torque':>8} {'t_mos':>7} {'t_rotor':>8} {'status':>8}")
    print("-" * 70)

    healthy = True
    for name in JOINTS:
        motor = robot.motors.get(name)
        if motor is None:
            print(f"{name:<15} {'-- not configured --':>50}")
            healthy = False
            continue

        state = motor.get_state()
        if state is None:
            print(f"{name:<15} {'-- NO CAN FEEDBACK --':>50}")
            healthy = False
            continue

        flag = "" if state.status_code == 0 else "  <-- FAULT"
        if state.status_code != 0:
            healthy = False
        print(
            f"{name:<15} {math.degrees(state.pos):9.2f} {state.vel:8.2f} {state.torq:8.2f} "
            f"{state.t_mos:7.1f} {state.t_rotor:8.1f} {state.status_code:8d}{flag}"
        )

    return healthy


def report_faults(robot) -> None:
    """Ask each RobStride motor for its detailed fault report, when supported."""
    print("\nDetailed fault reports:")
    for name in JOINTS:
        motor = robot.motors.get(name)
        if motor is None:
            continue
        try:
            report = motor.robstride_get_fault_report()
        except Exception as e:  # noqa: BLE001 - a motor that will not answer is the finding
            print(f"  {name:<15} could not read fault report: {e}")
            continue
        print(f"  {name:<15} {report}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--can", default="can4", help="CAN interface (default: can4, the USB adapter)")
    parser.add_argument("--robot-id", default="follower1")
    parser.add_argument("--fps", type=int, default=30, help="ramp update rate")
    parser.add_argument("--duration", type=float, default=3.0, help="seconds to ramp to home")
    parser.add_argument(
        "--tolerance", type=float, default=3.0, help="degrees from 0 still counted as home (default: 3)"
    )
    parser.add_argument("--check-only", action="store_true", help="report state and exit without moving")
    parser.add_argument("--clear-errors", action="store_true", help="clear latched motor errors first")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)-7s %(message)s")

    robot = build_robot(args.can, args.robot_id)
    print(f"Connecting to {args.can} ...")
    robot.connect(calibrate=False)

    try:
        healthy = report_motor_state(robot)
        report_faults(robot)

        if args.clear_errors:
            print("\nClearing latched motor errors ...")
            for name in JOINTS:
                motor = robot.motors.get(name)
                if motor is None:
                    continue
                try:
                    motor.clear_error()
                    print(f"  {name:<15} cleared")
                except Exception as e:  # noqa: BLE001
                    print(f"  {name:<15} clear_error failed: {e}")
            # Clearing a fault drops a RobStride motor back to DISABLED. Without
            # this the arm silently ignores every command that follows.
            print("Re-enabling motors after clearing ...")
            robot.bus.enable_all()
            healthy = report_motor_state(robot)

        if args.check_only:
            print("\n--check-only: not moving.")
            return 0 if healthy else 1

        if not healthy:
            print("\nMotors report a fault or missing feedback. NOT homing.")
            print("Re-run with --clear-errors, or power-cycle the arm, then try again.")
            return 1

        pose = _read_robot_action_pose(robot)
        if pose is None:
            print("\nCould not read the current pose; refusing to move.")
            return 1

        # Torque must be on or every command below is silently ignored.
        print("Ensuring motor torque is enabled ...")
        robot.bus.enable_all()

        before = {n: math.degrees(robot.motors[n].get_state().pos) for n in JOINTS if robot.motors.get(n)}

        print(f"\nRamping to home over {args.duration:.1f}s ...")
        return_robot_to_home(robot, args.fps, duration_s=args.duration)

        report_motor_state(robot)

        # Verify it actually moved. Reporting "Home." without checking is how a
        # dead-command bug looks like success.
        for motor in robot.motors.values():
            motor.request_feedback()
        robot.bus.poll_feedback_once()

        residual, moved = {}, 0.0
        for name in before:
            state = robot.motors[name].get_state()
            if state is None:
                continue
            now = math.degrees(state.pos)
            residual[name] = now
            moved = max(moved, abs(now - before[name]))

        off_home = {n: v for n, v in residual.items() if abs(v) > args.tolerance}
        if moved < 0.5 and off_home:
            print(f"\nFAILED: no joint moved more than {moved:.2f}°, and these are still off home:")
            for n, v in sorted(off_home.items(), key=lambda kv: -abs(kv[1])):
                print(f"   {n:<15} {v:+.2f}°")
            print("\nThe commands were sent but the arm did not respond -- torque is probably off.")
            print("Try: python inference/go_home.py --clear-errors   (it re-enables afterwards)")
            return 1

        if off_home:
            print(f"\nPARTIAL: moved {moved:.2f}° but these remain beyond ±{args.tolerance}°:")
            for n, v in sorted(off_home.items(), key=lambda kv: -abs(kv[1])):
                print(f"   {n:<15} {v:+.2f}°")
            return 1

        print(f"\nHome. (largest joint travel {moved:.2f}°, all within ±{args.tolerance}°)")
        return 0
    finally:
        robot.disconnect()


if __name__ == "__main__":
    sys.exit(main())
