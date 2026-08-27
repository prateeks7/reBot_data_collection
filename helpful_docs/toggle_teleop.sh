#!/usr/bin/env bash
set -u

# Toggle LeRobot teleoperation without touching unrelated processes.
# Press Enter to start. Press Enter again to stop only the process started here.
# Type q then Enter to quit.

ROBOT_TYPE="${ROBOT_TYPE:-seeed_b601_rs_follower}"
ROBOT_PORT="${ROBOT_PORT:-can4}"
ROBOT_ID="${ROBOT_ID:-follower1}"
ROBOT_CAN_ADAPTER="${ROBOT_CAN_ADAPTER:-socketcan}"

TELEOP_TYPE="${TELEOP_TYPE:-rebot_arm_102_leader}"
TELEOP_PORT="${TELEOP_PORT:-/dev/ttyUSB0}"
TELEOP_ID="${TELEOP_ID:-rebot_arm_102_leader}"

LOG_FILE="${LOG_FILE:-/tmp/lerobot_teleoperate_toggle.log}"
STARTUP_WAIT_S="${STARTUP_WAIT_S:-8}"

child_pid=""

is_running() {
  [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" 2>/dev/null
}

start_teleop() {
  if is_running; then
    echo "teleoperate already running: pid=${child_pid}"
    return
  fi

  if ! command -v lerobot-teleoperate >/dev/null 2>&1; then
    echo "error: lerobot-teleoperate not found in PATH"
    echo "activate the rs environment first, then rerun this script"
    return 1
  fi

  if [[ ! -e "/sys/class/net/${ROBOT_PORT}" ]]; then
    echo "error: robot CAN interface not found: ${ROBOT_PORT}"
    echo "check with: ip -br link"
    return 1
  fi

  if [[ ! -e "${TELEOP_PORT}" ]]; then
    echo "error: leader serial port not found: ${TELEOP_PORT}"
    echo "check with: ls -l /dev/ttyUSB* /dev/ttyACM*"
    return 1
  fi

  echo "starting teleoperate; log: ${LOG_FILE}"
  echo "---- start $(date -Is) ----" >>"${LOG_FILE}"
  setsid lerobot-teleoperate \
    --robot.type="${ROBOT_TYPE}" \
    --robot.port="${ROBOT_PORT}" \
    --robot.id="${ROBOT_ID}" \
    --robot.can_adapter="${ROBOT_CAN_ADAPTER}" \
    --teleop.type="${TELEOP_TYPE}" \
    --teleop.port="${TELEOP_PORT}" \
    --teleop.id="${TELEOP_ID}" \
    >>"${LOG_FILE}" 2>&1 </dev/null &

  child_pid=$!
  for _ in $(seq 1 "${STARTUP_WAIT_S}"); do
    if ! is_running; then
      break
    fi
    sleep 1
  done

  if is_running; then
    echo "started: pid=${child_pid}"
    echo "if it is not moving/connected, type log to inspect startup output"
  else
    echo "teleoperate exited during startup. Last log lines:"
    tail -40 "${LOG_FILE}" 2>/dev/null || true
    child_pid=""
  fi
}

stop_teleop() {
  if ! is_running; then
    echo "teleoperate is not running"
    child_pid=""
    return
  fi

  echo "stopping teleoperate: pid=${child_pid}"
  kill -TERM "-${child_pid}" 2>/dev/null || kill -TERM "${child_pid}" 2>/dev/null || true

  for _ in {1..30}; do
    if ! is_running; then
      wait "${child_pid}" 2>/dev/null || true
      child_pid=""
      echo "disconnected"
      return
    fi
    sleep 0.1
  done

  echo "teleoperate did not stop after SIGTERM; sending SIGKILL to child process group"
  kill -KILL "-${child_pid}" 2>/dev/null || kill -KILL "${child_pid}" 2>/dev/null || true
  wait "${child_pid}" 2>/dev/null || true
  child_pid=""
  echo "disconnected"
}

cleanup() {
  if is_running; then
    stop_teleop
  fi
}

trap cleanup INT TERM EXIT

cat <<EOF
Teleoperation toggle
  robot:  ${ROBOT_TYPE} on ${ROBOT_PORT}
  leader: ${TELEOP_TYPE} on ${TELEOP_PORT}
  log:    ${LOG_FILE}

Press Enter to connect/disconnect. Type q then Enter to quit.
EOF

while true; do
  if is_running; then
    prompt="[running] Enter=disconnect, q=quit > "
  else
    prompt="[stopped] Enter=connect, q=quit > "
  fi

  IFS= read -r -p "${prompt}" line
  case "${line}" in
    q|Q|quit|exit)
      break
      ;;
    "")
      if is_running; then
        stop_teleop
      else
        start_teleop
      fi
      ;;
    status)
      if is_running; then
        echo "running: pid=${child_pid}"
      else
        echo "stopped"
      fi
      ;;
    log)
      tail -80 "${LOG_FILE}" 2>/dev/null || true
      ;;
    *)
      echo "unknown command. Use Enter, status, log, or q."
      ;;
  esac
done
