#!/usr/bin/env bash
# Bring up CAN, check the motors for faults, park the arm at home, then start
# the async policy server.
#
# Homes the arm and gates the server on it: if a motor is faulted or the arm
# does not actually reach home, the server is not started. The robot_client
# homes again after it connects, but that only happens if the client gets that
# far -- this makes the arm's pose independent of the client surviving startup.
#
# Usage:
#   inference/start_async_server.sh                 # fault check + home + server
#   inference/start_async_server.sh --no-server     # fault check + home, no server
#   inference/start_async_server.sh --no-home       # fault check only, do not move
#   inference/start_async_server.sh --clear-errors  # clear latched faults first
set -Eeuo pipefail

REPO_DIR="/home/seeed_pk/Documents/rs"
CONDA_ENV="${CONDA_ENV:-rs}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
FPS="${FPS:-30}"
HOME_DURATION="${HOME_DURATION:-3.0}"
export TORCHINDUCTOR_CACHE_DIR="${TORCHINDUCTOR_CACHE_DIR:-${REPO_DIR}/.inductor_cache}"

START_SERVER=true
DO_HOME=true
CLEAR_ERRORS=false

while (($#)); do
  case "$1" in
    --no-server)    START_SERVER=false; shift ;;
    --no-home)      DO_HOME=false; shift ;;
    --clear-errors) CLEAR_ERRORS=true; shift ;;
    --port)         PORT="${2:?}"; shift 2 ;;
    --fps)          FPS="${2:?}"; shift 2 ;;
    -h|--help)      sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

cd "${REPO_DIR}"

# shellcheck disable=SC1091
source ~/miniforge3/etc/profile.d/conda.sh
conda activate "${CONDA_ENV}"

echo "==> Bringing up CAN"
# REBOT_LIB_ONLY makes record_rebot_vla.sh define its functions without running.
REBOT_LIB_ONLY=true source ./record_rebot_vla.sh
setup_can
echo "    CAN interface: ${CAN_IFACE}"

# go_home.py verifies the arm actually reached home and exits non-zero if not,
# so a failure here stops the server from starting. Torque is dropped when
# go_home disconnects, but the arm is geared enough to hold its pose; the client
# homes again after it connects anyway.
echo
if [[ "${DO_HOME}" == "true" ]]; then
  echo "==> Checking motors and homing the arm"
else
  echo "==> Checking motors for faults (--no-home: not moving)"
fi
check_args=(--can "${CAN_IFACE}" --fps "${FPS}" --duration "${HOME_DURATION}")
[[ "${CLEAR_ERRORS}" == "true" ]] && check_args+=(--clear-errors)
[[ "${DO_HOME}" == "true" ]] || check_args+=(--check-only)

if ! python inference/go_home.py "${check_args[@]}"; then
  echo
  echo "!! Motor fault, or the arm did not reach home. Not starting the server." >&2
  echo "   Inspect with: python inference/go_home.py --check-only" >&2
  echo "   Then retry with --clear-errors, or power-cycle the arm." >&2
  exit 1
fi

# Only reachable when go_home.py exited 0, which for a homing run means it
# verified every joint is within tolerance of 0.
if [[ "${DO_HOME}" == "true" ]]; then
  ARM_STATE="Arm verified at home."
else
  ARM_STATE="Arm NOT homed (--no-home); the robot client will home it on connect."
fi

if [[ "${START_SERVER}" == "false" ]]; then
  echo
  echo "==> --no-server: done. ${ARM_STATE}"
  exit 0
fi

echo
echo "==> Starting policy server on ${HOST}:${PORT} (fps ${FPS})"
echo "    Inductor cache: ${TORCHINDUCTOR_CACHE_DIR}"
echo "    ${ARM_STATE} Start the robot client in another terminal."
echo

exec python -m lerobot.async_inference.policy_server \
  --host="${HOST}" \
  --port="${PORT}" \
  --fps="${FPS}"
