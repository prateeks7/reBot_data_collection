#!/usr/bin/env bash
set -euo pipefail

# Defaults you may edit.
CONDA_ENV="${CONDA_ENV:-rs}"
CAN_IFACE="${CAN_IFACE:-auto}"
CAN_BITRATE="${CAN_BITRATE:-1000000}"
CAN_RESTART_MS="${CAN_RESTART_MS:-100}"
LEADER_PORT="${LEADER_PORT:-/dev/ttyUSB0}"

ROBOT_TYPE="${ROBOT_TYPE:-seeed_b601_rs_follower}"
ROBOT_ID="${ROBOT_ID:-follower1}"
ROBOT_CAN_ADAPTER="${ROBOT_CAN_ADAPTER:-socketcan}"

TELEOP_TYPE="${TELEOP_TYPE:-rebot_arm_102_leader}"
TELEOP_ID="${TELEOP_ID:-rebot_arm_102_leader}"

DO_FOLLOWER_CALIBRATE="${DO_FOLLOWER_CALIBRATE:-0}"
DO_LEADER_CALIBRATE="${DO_LEADER_CALIBRATE:-0}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --can canX              Use a specific CAN interface instead of auto-detect.
  --leader /dev/ttyUSB0   Leader arm serial port. Defaults to ${LEADER_PORT}.
  --bitrate 1000000       CAN bitrate. Defaults to ${CAN_BITRATE}.
  --calibrate-follower    Run follower calibration before teleoperation.
  --calibrate-leader      Run leader calibration before teleoperation.
  --calibrate-all         Run both calibrations before teleoperation.
  -h, --help              Show this help.

Environment overrides:
  CAN_IFACE=can4 LEADER_PORT=/dev/ttyUSB0 $(basename "$0")
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --can)
      CAN_IFACE="${2:?missing value for --can}"
      shift 2
      ;;
    --leader)
      LEADER_PORT="${2:?missing value for --leader}"
      shift 2
      ;;
    --bitrate)
      CAN_BITRATE="${2:?missing value for --bitrate}"
      shift 2
      ;;
    --calibrate-follower)
      DO_FOLLOWER_CALIBRATE=1
      shift
      ;;
    --calibrate-leader)
      DO_LEADER_CALIBRATE=1
      shift
      ;;
    --calibrate-all)
      DO_FOLLOWER_CALIBRATE=1
      DO_LEADER_CALIBRATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

activate_conda_env() {
  if [[ -n "${CONDA_PREFIX:-}" && "$(basename "${CONDA_PREFIX}")" == "${CONDA_ENV}" ]]; then
    return
  fi

  if command -v conda >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate "${CONDA_ENV}"
    return
  fi

  for conda_sh in "${HOME}/miniconda3/etc/profile.d/conda.sh" "${HOME}/anaconda3/etc/profile.d/conda.sh"; do
    if [[ -f "${conda_sh}" ]]; then
      # shellcheck disable=SC1090
      source "${conda_sh}"
      conda activate "${CONDA_ENV}"
      return
    fi
  done

  echo "warning: conda was not found; continuing with current shell environment" >&2
}

list_can_interfaces() {
  local c
  shopt -s nullglob
  for c in /sys/class/net/can*; do
    echo "$(basename "${c}") -> $(readlink -f "${c}/device")"
  done
  shopt -u nullglob
}

detect_can_iface() {
  local c device first_can=""
  shopt -s nullglob
  for c in /sys/class/net/can*; do
    [[ -z "${first_can}" ]] && first_can="$(basename "${c}")"
    device="$(readlink -f "${c}/device")"
    if [[ "${device}" == *usb* ]]; then
      basename "${c}"
      shopt -u nullglob
      return
    fi
  done
  shopt -u nullglob

  if [[ -n "${first_can}" ]]; then
    echo "${first_can}"
    return
  fi

  return 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

setup_can() {
  echo "CAN interfaces:"
  list_can_interfaces || true

  if [[ "${CAN_IFACE}" == "auto" ]]; then
    CAN_IFACE="$(detect_can_iface)" || {
      echo "error: no canX interface found under /sys/class/net" >&2
      exit 1
    }
  fi

  if [[ ! -e "/sys/class/net/${CAN_IFACE}" ]]; then
    echo "error: CAN interface does not exist: ${CAN_IFACE}" >&2
    exit 1
  fi

  echo "Using CAN interface: ${CAN_IFACE}"
  sudo ip link set "${CAN_IFACE}" down 2>/dev/null || true
  sudo ip link set "${CAN_IFACE}" type can bitrate "${CAN_BITRATE}" restart-ms "${CAN_RESTART_MS}"
  sudo ip link set "${CAN_IFACE}" txqueuelen 1000
  sudo ip link set "${CAN_IFACE}" up
  ip -details link show "${CAN_IFACE}"
}

calibrate_follower() {
  echo
  echo "Starting follower calibration on ${CAN_IFACE}."
  echo "When prompted by LeRobot, press c, Enter, then Enter again as in steps.md."
  lerobot-calibrate \
    --robot.type="${ROBOT_TYPE}" \
    --robot.port="${CAN_IFACE}" \
    --robot.id="${ROBOT_ID}" \
    --robot.can_adapter="${ROBOT_CAN_ADAPTER}"
}

calibrate_leader() {
  echo
  echo "Starting leader calibration on ${LEADER_PORT}."
  sudo chmod 666 "${LEADER_PORT}"
  lerobot-calibrate \
    --teleop.type="${TELEOP_TYPE}" \
    --teleop.port="${LEADER_PORT}" \
    --teleop.id="${TELEOP_ID}"
}

run_teleop() {
  if [[ ! -e "${LEADER_PORT}" ]]; then
    echo "error: leader port not found: ${LEADER_PORT}" >&2
    echo "Use --leader /dev/ttyUSBX or run lerobot-find-port." >&2
    exit 1
  fi

  sudo chmod 666 "${LEADER_PORT}"
  echo
  echo "Starting teleoperation:"
  echo "  robot:  ${ROBOT_TYPE} on ${CAN_IFACE}"
  echo "  leader: ${TELEOP_TYPE} on ${LEADER_PORT}"
  lerobot-teleoperate \
    --robot.type="${ROBOT_TYPE}" \
    --robot.port="${CAN_IFACE}" \
    --robot.id="${ROBOT_ID}" \
    --robot.can_adapter="${ROBOT_CAN_ADAPTER}" \
    --teleop.type="${TELEOP_TYPE}" \
    --teleop.port="${LEADER_PORT}" \
    --teleop.id="${TELEOP_ID}"
}

activate_conda_env
require_command ip
require_command lerobot-calibrate
require_command lerobot-teleoperate

setup_can

if [[ "${DO_FOLLOWER_CALIBRATE}" == "1" ]]; then
  calibrate_follower
fi

if [[ "${DO_LEADER_CALIBRATE}" == "1" ]]; then
  calibrate_leader
fi

run_teleop
