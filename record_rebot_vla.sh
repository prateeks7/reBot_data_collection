#!/usr/bin/env bash
set -Eeuo pipefail

# reBot B601-RS VLA data collection launcher (Seeed DepthCameraSupport branch).
#
# Records a resumable LeRobot v3 dataset from the Orbbec scene camera and the
# RealSense D405 wrist camera. Every default can be overridden with an
# environment variable or a command-line flag.
#
# Controls while recording:
#   RIGHT / Enter  save the episode, home the arm, then start the reset countdown
#   LEFT           discard the current episode and record it again
#   ESC            save what is done and stop cleanly (resumable)
#   Ctrl-C         same as ESC; the arm is homed and torque-disabled first

USER_HOME_DIR="$(getent passwd "$(id -u)" | cut -d: -f6)"
CONDA_ENV="${CONDA_ENV:-rs}"

# --- CAN / teleop -----------------------------------------------------------
CAN_IFACE="${CAN_IFACE:-auto}"
CAN_BITRATE="${CAN_BITRATE:-1000000}"
CAN_RESTART_MS="${CAN_RESTART_MS:-100}"
CAN_USB_RESET="${CAN_USB_RESET:-true}"   # power-cycle the USB-CAN adapter before each run
LEADER_PORT="${LEADER_PORT:-/dev/ttyUSB0}"

ROBOT_TYPE="${ROBOT_TYPE:-seeed_b601_rs_follower}"
ROBOT_ID="${ROBOT_ID:-follower1}"
ROBOT_CAN_ADAPTER="${ROBOT_CAN_ADAPTER:-socketcan}"
TELEOP_TYPE="${TELEOP_TYPE:-rebot_arm_102_leader}"
TELEOP_ID="${TELEOP_ID:-rebot_arm_102_leader}"

# --- cameras ----------------------------------------------------------------
# Comma-separated list of camera tokens; each token becomes the dataset key
# `observation.images.<token>`. See camera_entry() for the catalog.
CAMERAS="${CAMERAS:-auto}"   # auto = record every attached camera, colour + depth
ORBBEC_ID="${ORBBEC_ID:-}"               # Orbbec serial or product name; empty = auto-detect
D405_SERIAL="${D405_SERIAL:-427622271449}"
D435I_SERIAL="${D435I_SERIAL:-261722076642}"
CAMERA_FPS="${CAMERA_FPS:-30}"   # also the teleop control rate: one loop drives both
CAMERA_WIDTH="${CAMERA_WIDTH:-640}"
CAMERA_HEIGHT="${CAMERA_HEIGHT:-480}"
SCENE_ROTATION="${SCENE_ROTATION:-0}"
WRIST_ROTATION="${WRIST_ROTATION:-0}"
CHECK_CAMERAS="${CHECK_CAMERAS:-true}"   # open every camera and validate real RGB frames first
PROBE_SECONDS="${PROBE_SECONDS:-3}"

# --- dataset ----------------------------------------------------------------
DATASET_REPO_ID="${DATASET_REPO_ID:-seeed_pk/rebot_b601_rs_brown_sugar}"
DATASET_ROOT="${DATASET_ROOT:-${USER_HOME_DIR}/Documents/rs/datasets/rebot_b601_rs_vla}"
TASK="${TASK:-Pick one sugar cube and put it in the cup}"
TARGET_EPISODES="${TARGET_EPISODES:-50}"
EPISODE_TIME_S="${EPISODE_TIME_S:-0}"    # 0 = end the episode manually with RIGHT
RESET_TIME_S="${RESET_TIME_S:-10}"
DISCARD_RESET_TIME_S="${DISCARD_RESET_TIME_S:-5}"   # reset window after LEFT (discard+redo)
ENGAGE_RAMP_S="${ENGAGE_RAMP_S:-1.0}"               # recorded lead-in from home onto the leader
# Optional: hold after the reset countdown until every leader joint is within
# this many degrees of home. 0 = off, which is right when ENGAGE_RAMP_S > 0.
LEADER_HOME_TOLERANCE_DEG="${LEADER_HOME_TOLERANCE_DEG:-0}"
PUSH_TO_HUB="${PUSH_TO_HUB:-false}"
DISPLAY_DATA="${DISPLAY_DATA:-true}"     # Rerun live camera viewer; --no-display to disable
VIEWER_DISPLAY="${VIEWER_DISPLAY:-}"     # X display for the viewer window; empty = autodetect
VIDEO_CODEC="${VIDEO_CODEC:-h264}"
MIN_FREE_GB="${MIN_FREE_GB:-10}"

ORBBEC_UDEV_RULES="/etc/udev/rules.d/99-obsensor-libusb.rules"

CAMERA_CONFIG=""
CAN_CONFIGURED="false"
RECORDER_STARTED="false"
# Set by apply_camera_selection once the camera list is known. Initialised here,
# above the REBOT_LIB_ONLY guard, so scripts that source this file for its
# functions get it too -- print_capture_plan reads it under `set -u`.
RECORD_DEPTH=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Records a resumable LeRobot dataset for VLA training. An existing dataset is
resumed automatically from its last completed episode.

Options:
  --task TEXT              Language task stored in the dataset.
  --episodes N             Target total completed episodes (default: ${TARGET_EPISODES}).
  --episode-seconds N      Max seconds per episode; 0 = press RIGHT when done (default: ${EPISODE_TIME_S}).
  --reset-seconds N        Environment reset countdown between episodes (default: ${RESET_TIME_S}).
  --discard-seconds N      Reset countdown after discarding with LEFT (default: ${DISCARD_RESET_TIME_S}).
  --engage-ramp S          Seconds at the start of each episode spent ramping
                           from home onto the leader (default: ${ENGAGE_RAMP_S}). Recorded,
                           so every episode's first frame is the same home pose.
  --leader-home-tolerance D  Optionally hold until the leader is within D degrees
                           of home before starting (default: ${LEADER_HOME_TOLERANCE_DEG}; 0 = off).
  --repo-id OWNER/NAME     Dataset repository ID (default: ${DATASET_REPO_ID}).
  --dataset-root PATH      Local dataset directory (default: ${DATASET_ROOT}).
  --cameras LIST           Comma-separated camera tokens, or 'auto' (default: ${CAMERAS}).
                           'auto' records colour + depth for every attached camera.
                             scene           Orbbec Gemini colour  -> observation.images.scene
                             wrist           RealSense D405 colour -> observation.images.wrist
                             overhead        RealSense D435i colour
                             scene_depth     Orbbec depth
                             wrist_depth     D405 depth
                             overhead_depth  D435i depth
                             none            Record proprioception only
  --fps N                  Dataset, camera and teleop control rate (default: ${CAMERA_FPS}).
                           One loop drives capture and the arm, so this is both.
                           30 matches the cameras' native rate; --fps 60 doubles
                           the data rate and the Jetson's encode load.
  --width N / --height N   Camera resolution (default: ${CAMERA_WIDTH}x${CAMERA_HEIGHT}).
  --orbbec-id ID           Orbbec serial or product name (default: auto-detect).
  --d405-serial SERIAL     RealSense D405 serial (default: ${D405_SERIAL}).
  --d435i-serial SERIAL    RealSense D435i serial (default: ${D435I_SERIAL}).
  --can canX               CAN interface, or auto (default: ${CAN_IFACE}).
  --no-can-reset           Skip the USB power-cycle of the CAN adapter.
  --leader PATH            Leader serial port (default: ${LEADER_PORT}).
  --skip-camera-check      Do not open/validate the cameras before recording.
  --push-to-hub            Upload to the Hugging Face Hub when finished.
  --display / --no-display Toggle the Rerun viewer (default: ${DISPLAY_DATA}).
  --viewer-display :N      X display for the viewer window (default: autodetect).
  -h, --help               Show this help.

Recording controls:
  RIGHT / Enter  Save the episode and start the reset countdown.
  LEFT           Discard the current episode and record it again.
  ESC            Save and stop cleanly; rerun this script to resume.
  Ctrl-C         Same as ESC.

Between episodes (after saving with RIGHT, and after discarding with LEFT):
  1. The follower ramps back to home (all joints 0) over ~3 s.
  2. Teleop is disengaged for the reset countdown, so the arm stays parked at
     home while you reset the scene.
  3. Recording starts with the follower still at home, so every episode's first
     frame is the same pose. The leader does NOT need to be aligned by hand.
  4. The first --engage-ramp seconds of the episode ramp the follower from home
     onto the leader, then you teleoperate normally. That lead-in is recorded.

Depth:
  Adding a *_depth token records two things. The dataset gets a pseudo-colour
  preview video (observation.images.<key>), and the sensor's raw uint16 depth is
  stored losslessly next to it:

    <dataset>/depth/<key>/episode_NNNNNN.mkv   FFV1 gray16le, bit-exact
    <dataset>/meta/depth_info.json             depth scale + intrinsics

  Depth is aligned to its colour camera on-device, so depth[y,x] and rgb[y,x] are
  the same point. Metres = pixel * depth_scale_m; 0 means no return. Train
  PointVLA and other RGB-D models on the .mkv files, not the preview video.
  MolmoAct 2 does not need any of this: it derives depth tokens from RGB.
EOF
}

info()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail "$1 must be a positive integer (got: $2)"
}

require_nonnegative_integer() {
  [[ "$2" =~ ^[0-9]+$ ]] || fail "$1 must be a non-negative integer (got: $2)"
}

speak() {
  command -v spd-say >/dev/null 2>&1 && spd-say --wait "$1" >/dev/null 2>&1 || true
}

activate_conda_env() {
  if [[ -n "${CONDA_PREFIX:-}" && "$(basename "${CONDA_PREFIX}")" == "${CONDA_ENV}" ]]; then
    return
  fi

  local conda_sh=""
  if command -v conda >/dev/null 2>&1; then
    conda_sh="$(conda info --base)/etc/profile.d/conda.sh"
  elif [[ -f "${USER_HOME_DIR}/miniforge3/etc/profile.d/conda.sh" ]]; then
    conda_sh="${USER_HOME_DIR}/miniforge3/etc/profile.d/conda.sh"
  fi

  [[ -n "${conda_sh}" && -f "${conda_sh}" ]] || fail "Conda was not found"
  # Conda's activation scripts reference unset variables.
  set +u
  # shellcheck disable=SC1090
  source "${conda_sh}"
  conda activate "${CONDA_ENV}"
  set -u
}

# ---------------------------------------------------------------------------
# Camera catalog
# ---------------------------------------------------------------------------

wants_camera() {
  [[ ",${CAMERAS}," == *",$1,"* ]]
}

uses_orbbec() { [[ ",${CAMERAS}," == *",scene,"* || ",${CAMERAS}," == *",scene_depth,"* ]]; }
uses_realsense() {
  [[ ",${CAMERAS}," == *",wrist,"* || ",${CAMERAS}," == *",wrist_depth,"* \
   || ",${CAMERAS}," == *",overhead,"* || ",${CAMERAS}," == *",overhead_depth,"* ]]
}

camera_entry() {
  local token="$1"
  local geom="width: ${CAMERA_WIDTH}, height: ${CAMERA_HEIGHT}, fps: ${CAMERA_FPS}"
  case "${token}" in
    scene)
      printf 'scene: {type: orbbec_color, serial_number_or_name: "%s", %s, color_mode: rgb, rotation: %s, warmup_s: 2}' \
        "${ORBBEC_ID}" "${geom}" "${SCENE_ROTATION}"
      ;;
    scene_depth)
      printf 'scene_depth: {type: orbbec_depth, serial_number_or_name: "%s", %s, depth_alpha: 0.2, rotation: %s, warmup_s: 5}' \
        "${ORBBEC_ID}" "${geom}" "${SCENE_ROTATION}"
      ;;
    wrist)
      printf 'wrist: {type: realsense_d405_color, serial_number_or_name: "%s", %s, color_mode: rgb, color_stream_format: rgb8, rotation: %s, warmup_s: 1}' \
        "${D405_SERIAL}" "${geom}" "${WRIST_ROTATION}"
      ;;
    wrist_depth)
      printf 'wrist_depth: {type: realsense_d405_depth, serial_number_or_name: "%s", %s, depth_alpha: 0.03, rotation: %s, warmup_s: 5}' \
        "${D405_SERIAL}" "${geom}" "${WRIST_ROTATION}"
      ;;
    overhead)
      printf 'overhead: {type: realsense_d435i_color, serial_number_or_name: "%s", %s, color_mode: rgb, color_stream_format: rgb8, rotation: 0, warmup_s: 1}' \
        "${D435I_SERIAL}" "${geom}"
      ;;
    overhead_depth)
      printf 'overhead_depth: {type: realsense_d435i_depth, serial_number_or_name: "%s", %s, max_depth_m: 2.0, depth_alpha: 0.2, rotation: 0, warmup_s: 5}' \
        "${D435I_SERIAL}" "${geom}"
      ;;
    *)
      fail "unknown camera token '${token}'; run --help for the catalog"
      ;;
  esac
}

# Probe the machine and enable colour + depth for every camera that is actually
# attached, so the common case needs no --cameras flag at all. CAMERA_PRESENT /
# CAMERA_ABSENT feed the capture-plan summary printed before recording starts.
declare -a CAMERA_PRESENT=()
declare -a CAMERA_ABSENT=()

autodetect_cameras() {
  [[ "${CAMERAS}" == "auto" ]] || return 0

  local report
  report="$(
    python - "${D405_SERIAL}" "${D435I_SERIAL}" <<'PY'
import sys

d405_serial, d435i_serial = sys.argv[1], sys.argv[2]
tokens, present, absent = [], [], []

try:
    from lerobot.cameras.orbbec.camera_orbbec import find_orbbec_cameras

    devices = find_orbbec_cameras()
except Exception as error:  # noqa: BLE001 - SDK missing or unreadable is just "absent"
    devices = []
    absent.append(f"scene|Orbbec|not detected ({type(error).__name__})")

if devices:
    device = devices[0]
    label = f'{device.get("name", "Orbbec")} ({device.get("serial_number") or device.get("id")})'
    tokens += ["scene", "scene_depth"]
    present.append(f"scene|{label}")
    present.append(f"scene_depth|{label}")
elif not absent:
    absent.append("scene|Orbbec|not connected")

try:
    import pyrealsense2 as rs

    found = {
        device.get_info(rs.camera_info.serial_number): device.get_info(rs.camera_info.name)
        for device in rs.context().query_devices()
    }
except Exception as error:  # noqa: BLE001
    found = {}
    absent.append(f"wrist|RealSense|not detected ({type(error).__name__})")

for serial, keys, fallback in (
    (d405_serial, ("wrist", "wrist_depth"), "RealSense D405"),
    (d435i_serial, ("overhead", "overhead_depth"), "RealSense D435i"),
):
    if serial in found:
        label = f"{found[serial]} ({serial})"
        tokens += list(keys)
        present += [f"{key}|{label}" for key in keys]
    else:
        absent.append(f"{keys[0]}|{fallback} ({serial})|not connected")

print("@@CAMERAS:" + ",".join(tokens))
for line in present:
    print("@@PRESENT:" + line)
for line in absent:
    print("@@ABSENT:" + line)
PY
  )"

  local detected
  detected="$(sed -n 's/^@@CAMERAS://p' <<<"${report}")"
  mapfile -t CAMERA_PRESENT < <(sed -n 's/^@@PRESENT://p' <<<"${report}")
  mapfile -t CAMERA_ABSENT < <(sed -n 's/^@@ABSENT://p' <<<"${report}")

  [[ -n "${detected}" ]] \
    || fail "No cameras detected. Connect one, or pass --cameras none to record proprioception only."
  CAMERAS="${detected}"
}

# Recomputed after autodetection, since `auto` decides the token list at runtime.
# Must stay above the REBOT_LIB_ONLY guard: scripts that source this file for its
# functions call it too, and anything defined below the guard never exists there.
apply_camera_selection() {
  validate_camera_tokens
  if [[ ",${CAMERAS}," == *"_depth,"* ]]; then
    RECORD_DEPTH=true
    # Raw depth roughly doubles the storage per camera; make sure there is room.
    MIN_FREE_GB=$(( MIN_FREE_GB > 40 ? MIN_FREE_GB : 40 ))
  fi
}

# camera_entry runs inside a command substitution, where `fail` could only kill
# the subshell. Validate the token list here instead, before it is used.
validate_camera_tokens() {
  local token
  local -a tokens=()
  IFS=',' read -r -a tokens <<<"${CAMERAS}"
  for token in "${tokens[@]}"; do
    case "${token}" in
      scene|scene_depth|wrist|wrist_depth|overhead|overhead_depth|none|"") ;;
      *) fail "unknown camera token '${token}' in --cameras; run --help for the catalog" ;;
    esac
  done
  if [[ ",${CAMERAS}," == *",none,"* && "${CAMERAS}" != "none" ]]; then
    fail "--cameras 'none' cannot be combined with other cameras"
  fi
}

make_camera_config() {
  if [[ "${CAMERAS}" == "none" || -z "${CAMERAS}" ]]; then
    CAMERA_CONFIG="{}"
    warn "No cameras selected; the dataset will contain proprioception only."
    return
  fi

  local token joined=""
  local -a tokens=()
  IFS=',' read -r -a tokens <<<"${CAMERAS}"
  for token in "${tokens[@]}"; do
    [[ -n "${token}" ]] || continue
    joined="${joined:+${joined}, }$(camera_entry "${token}")"
  done
  [[ -n "${joined}" ]] || fail "--cameras produced no cameras"
  CAMERA_CONFIG="{${joined}}"
}

dataset_image_keys() {
  local token out=""
  local -a tokens=()
  IFS=',' read -r -a tokens <<<"${CAMERAS}"
  for token in "${tokens[@]}"; do
    [[ -n "${token}" && "${token}" != "none" ]] || continue
    out="${out:+${out} }observation.images.${token}"
  done
  echo "${out}"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

check_python_environment() {
  if ! python -c "import lerobot, scipy, cv2" >/dev/null 2>&1; then
    python -c "import lerobot, scipy, cv2" || true
    fail "The '${CONDA_ENV}' environment is unhealthy; fix the import error above"
  fi

  if uses_realsense && ! python -c "import pyrealsense2" >/dev/null 2>&1; then
    fail "RealSense cameras were requested but pyrealsense2 does not import"
  fi
  if uses_orbbec && ! python -c "import pyorbbecsdk" >/dev/null 2>&1; then
    fail "Orbbec cameras were requested but pyorbbecsdk does not import"
  fi

  command -v lerobot-record >/dev/null 2>&1 \
    || fail "lerobot-record was not found in Conda environment '${CONDA_ENV}'"
}

# LeRobot >= 0.4 concatenates episode videos with av's `add_stream_from_template`,
# which only exists in PyAV >= 13. Older PyAV crashes *after* an episode is
# recorded, so catch it here instead.
check_video_stack() {
  python - <<'PY' || fail "PyAV cannot concatenate episode videos; see the message above"
import sys

import av
from lerobot.datasets import video_utils

major = int(av.__version__.split(".")[0])
if major >= 13:
    sys.exit(0)

source = ""
try:
    with open(video_utils.__file__, encoding="utf-8") as handle:
        source = handle.read()
except OSError:
    pass

if "add_stream_from_template" in source and "hasattr(output_container" in source:
    print(f"note: PyAV {av.__version__} is older than lerobot's pinned av>=15; "
          "using the compatibility path in video_utils.concatenate_video_files.")
    sys.exit(0)

print(
    f"PyAV {av.__version__} has no OutputContainer.add_stream_from_template, and\n"
    "lerobot/datasets/video_utils.py has no fallback. save_episode() will crash\n"
    "after the first episode is recorded. Fix with:\n"
    f"    pip install -U 'av>=15,<16'",
    file=sys.stderr,
)
sys.exit(1)
PY
}

# pyorbbecsdk talks to the camera over libusb, which needs the vendor udev rule.
# Without it /dev/bus/usb/... stays root-only and the SDK fails with
# "usbEnumerator openUsbDevice failed!" -- the failure that pushes people onto
# the raw /dev/videoN nodes, where the first node is the greyscale depth stream.
check_orbbec_udev_rules() {
  uses_orbbec || return 0
  [[ -f "${ORBBEC_UDEV_RULES}" ]] && return 0

  # pyorbbecsdk prints "load extensions from ..." to stdout when it is imported,
  # so tag the value we want and pick it back out.
  local shipped
  shipped="$(
    python -c 'import os,pyorbbecsdk;print("@@:"+os.path.join(os.path.dirname(pyorbbecsdk.__file__),"shared","99-obsensor-libusb.rules"))' \
      | sed -n 's/^@@://p'
  )"
  [[ -n "${shipped}" && -f "${shipped}" ]] \
    || fail "Orbbec udev rules are missing and pyorbbecsdk does not ship a copy at '${shipped}'"

  info "Installing Orbbec udev rules (needs sudo) -- one time only"
  sudo cp "${shipped}" "${ORBBEC_UDEV_RULES}"
  sudo udevadm control --reload
  sudo udevadm trigger
  sleep 2
  info "Installed ${ORBBEC_UDEV_RULES}"
}

# Resolve the Orbbec identifier to something the camera class accepts. It only
# matches on serial_number or product name -- never on the USB uid that
# `lerobot-find-cameras orbbec` prints when it cannot open the device.
resolve_orbbec_id() {
  uses_orbbec || return 0

  # pyorbbecsdk writes "load extensions from ..." to stdout on import, so the
  # answer is tagged and filtered back out here.
  ORBBEC_ID="$(
    python - "${ORBBEC_ID}" <<'PY' | sed -n 's/^@@://p'
import sys

from lerobot.cameras.orbbec.camera_orbbec import find_orbbec_cameras

requested = sys.argv[1].strip()
devices = find_orbbec_cameras()
if not devices:
    raise SystemExit("No Orbbec camera detected. Check the USB cable and `lsusb -d 2bc5:`.")

if requested:
    for device in devices:
        if requested in (device.get("serial_number"), device.get("name")):
            print("@@:" + requested)
            raise SystemExit(0)
    available = ", ".join(
        f'{d.get("name")} (serial={d.get("serial_number")})' for d in devices
    )
    raise SystemExit(f"Orbbec camera '{requested}' not found. Available: {available}")

device = devices[0]
serial = device.get("serial_number")
if serial:
    print("@@:" + serial)
    raise SystemExit(0)

# No serial means the SDK could not open the device -- almost always the udev
# rules. The name still works as long as there is exactly one Orbbec attached.
name = device.get("name")
if name and sum(1 for d in devices if d.get("name") == name) == 1:
    print("@@:" + name)
    raise SystemExit(0)

raise SystemExit(
    "Could not read the Orbbec serial number and the product name is ambiguous.\n"
    "The SDK usually cannot read the serial when the libusb udev rules are\n"
    "missing. Install them, replug the camera, and try again:\n"
    "    sudo cp <pyorbbecsdk>/shared/99-obsensor-libusb.rules /etc/udev/rules.d/\n"
    "    sudo udevadm control --reload && sudo udevadm trigger\n"
    "Otherwise pass the camera explicitly with --orbbec-id."
)
PY
  )"
  info "Orbbec camera: ${ORBBEC_ID}"
}

check_realsense_devices() {
  uses_realsense || return 0

  local -a expected=()
  if wants_camera wrist || wants_camera wrist_depth; then expected+=("${D405_SERIAL}"); fi
  if wants_camera overhead || wants_camera overhead_depth; then expected+=("${D435I_SERIAL}"); fi

  python - "${expected[@]}" <<'PY'
import sys

import pyrealsense2 as rs

expected = set(sys.argv[1:])
devices = {
    device.get_info(rs.camera_info.serial_number): (
        device.get_info(rs.camera_info.name),
        device.get_info(rs.camera_info.usb_type_descriptor),
    )
    for device in rs.context().query_devices()
}

missing = expected - set(devices)
if missing:
    available = ", ".join(f"{s} ({n})" for s, (n, _) in devices.items()) or "none"
    raise SystemExit(
        f"Missing RealSense camera(s): {', '.join(sorted(missing))}. Connected: {available}"
    )

for serial in sorted(expected):
    name, usb = devices[serial]
    print(f"RealSense {name} {serial}: USB {usb}")
    if usb.startswith("2"):
        raise SystemExit(
            f"RealSense {serial} negotiated USB {usb}; move it to a USB 3.x port "
            "before recording or it will drop frames"
        )
PY
}

check_usb_link_speed() {
  uses_orbbec || return 0
  local speed dev
  for dev in /sys/bus/usb/devices/*; do
    [[ -f "${dev}/idVendor" && -f "${dev}/speed" ]] || continue
    [[ "$(<"${dev}/idVendor")" == "2bc5" ]] || continue
    speed="$(<"${dev}/speed")"
    if (( ${speed%%.*} < 5000 )); then
      warn "Orbbec camera is on a USB ${speed} Mbps link (USB 2.x)."
      warn "  ${CAMERA_WIDTH}x${CAMERA_HEIGHT}@${CAMERA_FPS} colour+depth may drop frames."
      warn "  Use a USB 3 port and a USB 3 cable for full bandwidth."
    else
      info "Orbbec USB link: ${speed} Mbps"
    fi
  done
}

# Open every requested camera through the exact same code path lerobot-record
# uses and confirm the frames are real colour at the requested rate. This is
# what catches "the video came out black and white".
check_camera_streams() {
  [[ "${CHECK_CAMERAS}" == "true" ]] || { warn "Skipping the camera stream check"; return 0; }
  [[ "${CAMERA_CONFIG}" != "{}" ]] || return 0

  info "Validating camera streams (${PROBE_SECONDS}s per camera)..."
  if ! python - "${CAMERA_CONFIG}" "${CAMERA_FPS}" "${CAMERA_WIDTH}" "${CAMERA_HEIGHT}" "${PROBE_SECONDS}" <<'PY'
import sys
import time

import draccus
import numpy as np
import yaml

from lerobot.cameras import CameraConfig  # noqa: F401
from lerobot.cameras.opencv.configuration_opencv import OpenCVCameraConfig  # noqa: F401
from lerobot.cameras.orbbec.configuration_orbbec import (  # noqa: F401
    OrbbecColorCameraConfig,
    OrbbecDepthCameraConfig,
)
from lerobot.cameras.realsense.configuration_rs_d405 import (  # noqa: F401
    RealSenseD405ColorCameraConfig,
    RealSenseD405DepthCameraConfig,
)
from lerobot.cameras.realsense.configuration_rs_d435i import (  # noqa: F401
    RealSenseD435iColorCameraConfig,
    RealSenseD435iDepthCameraConfig,
)
from lerobot.cameras.utils import make_cameras_from_configs

raw_config, fps, width, height, probe_s = sys.argv[1:6]
fps, width, height, probe_s = int(fps), int(width), int(height), float(probe_s)

configs = draccus.decode(dict[str, CameraConfig], yaml.safe_load(raw_config))
cameras = make_cameras_from_configs(configs)

failures = []
try:
    for key, camera in cameras.items():
        try:
            camera.connect()
        except Exception as error:  # noqa: BLE001 - report, do not abort the other cameras
            failures.append(f"{key}: could not open the camera: {error}")

    # Read every camera concurrently, the way the record loop does, so a camera
    # that only streams while it is the sole client cannot pass here and fail
    # during recording.
    live = {k: c for k, c in cameras.items() if c.is_connected}
    collected = {k: [] for k in live}
    stalled = {}
    started = time.perf_counter()
    deadline = started + probe_s
    while time.perf_counter() < deadline and len(stalled) < len(live):
        for key, camera in live.items():
            if key in stalled:
                continue
            try:
                collected[key].append(camera.async_read(timeout_ms=5000))
            except Exception as error:  # noqa: BLE001 - a stalled stream is a finding
                stalled[key] = error
    elapsed = time.perf_counter() - started

    for key, camera in live.items():
        is_depth = getattr(camera, "KIND", None) == "depth"
        frames = collected[key]

        if key in stalled:
            failures.append(
                f"{key}: stream stalled after {len(frames)} frame(s): {stalled[key]}"
            )
            continue

        if not frames:
            failures.append(f"{key}: no frames in {probe_s}s")
            continue

        frame = frames[-1]
        measured_fps = len(frames) / elapsed
        # A 90/270 degree rotation swaps height and width.
        shape_ok = (
            frame.ndim == 3
            and frame.shape[2] == 3
            and frame.shape[:2] in ((height, width), (width, height))
        )
        colour_pixels = int(np.count_nonzero(frame.max(axis=2) != frame.min(axis=2)))
        colour_ratio = colour_pixels / (frame.shape[0] * frame.shape[1])
        spread = float(np.percentile(frame, 99) - np.percentile(frame, 1))

        status = "ok"
        if not shape_ok:
            failures.append(
                f"{key}: expected a {height}x{width}x3 frame, got {frame.shape} ({frame.dtype})"
            )
            status = "BAD SHAPE"
        elif spread < 4:
            failures.append(
                f"{key}: frames are almost uniform (1-99 percentile spread {spread:.1f}); "
                "the camera is capped, unplugged, or looking at a blank scene"
            )
            status = "BLANK"
        elif not is_depth and colour_ratio < 0.02:
            failures.append(
                f"{key}: only {colour_ratio:.1%} of pixels differ across R/G/B, i.e. the stream is "
                "greyscale, not colour. This happens when a depth/IR node is opened as a colour "
                "camera -- check the camera type and serial in --cameras"
            )
            status = "GREYSCALE"
        elif measured_fps < 0.7 * fps:
            failures.append(
                f"{key}: only sustained {measured_fps:.1f} fps of the requested {fps} fps; "
                "lower --fps or move the camera to a faster USB port"
            )
            status = "SLOW"

        print(
            f"  {key:<16} {frame.shape[1]}x{frame.shape[0]}  "
            f"{measured_fps:5.1f} fps  colour {colour_ratio:5.1%}  {status}"
        )
finally:
    for camera in cameras.values():
        try:
            if camera.is_connected:
                camera.disconnect()
        except Exception as error:  # noqa: BLE001 - teardown must not mask the real failure
            print(f"  warning: failed to close a camera: {error}", file=sys.stderr)

if failures:
    print("", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
PY
  then
    fail "Camera validation failed; fix the cameras before recording"
  fi
}

check_leader_port() {
  [[ -e "${LEADER_PORT}" ]] || fail "Leader port not found: ${LEADER_PORT} (run lerobot-find-port)"
  if [[ ! -r "${LEADER_PORT}" || ! -w "${LEADER_PORT}" ]]; then
    info "Granting access to ${LEADER_PORT} (needs sudo)"
    sudo chmod 666 "${LEADER_PORT}"
  fi
}

check_disk_space() {
  local target="${DATASET_ROOT}"
  while [[ ! -d "${target}" && "${target}" != "/" ]]; do target="$(dirname "${target}")"; done
  local free_gb
  free_gb="$(df -BG --output=avail "${target}" | tail -1 | tr -dc '0-9')"
  if (( free_gb < MIN_FREE_GB )); then
    fail "Only ${free_gb} GB free on ${target}; need at least ${MIN_FREE_GB} GB (override with MIN_FREE_GB)"
  fi
  info "Free disk space: ${free_gb} GB"
}

check_no_existing_recording() {
  local existing
  existing="$(pgrep -af '(^|/)lerobot-record( |$)' || true)"
  if [[ -n "${existing}" ]]; then
    echo "${existing}" >&2
    fail "Another lerobot-record process is already running; stop it first"
  fi
}

stop_stale_viewer() {
  pkill -f '/rerun --port=9876' 2>/dev/null || true
}

# Rerun's viewer is a native window, so it needs a reachable X display. Launched
# over SSH or from an editor terminal, DISPLAY is often unset and `rr.spawn()`
# sits there "loading" forever waiting for a window that can never appear. Find
# the live X server and point the viewer at it.
setup_viewer_display() {
  [[ "${DISPLAY_DATA}" == "true" ]] || return 0

  if [[ -z "${VIEWER_DISPLAY}" ]]; then
    if [[ -n "${DISPLAY:-}" ]]; then
      VIEWER_DISPLAY="${DISPLAY}"
    else
      local socket
      shopt -s nullglob
      for socket in /tmp/.X11-unix/X*; do
        VIEWER_DISPLAY=":${socket##*/X}"
        break
      done
      shopt -u nullglob
    fi
  fi

  if [[ -z "${VIEWER_DISPLAY}" ]]; then
    warn "No X display found; disabling the live viewer (use --no-display to silence this)."
    DISPLAY_DATA=false
    return 0
  fi

  export DISPLAY="${VIEWER_DISPLAY}"
  # Fall back to the session's gdm cookie when the user has no ~/.Xauthority.
  if [[ -z "${XAUTHORITY:-}" && -r "/run/user/$(id -u)/gdm/Xauthority" ]]; then
    export XAUTHORITY="/run/user/$(id -u)/gdm/Xauthority"
  fi

  if ! DISPLAY="${VIEWER_DISPLAY}" timeout 5 xdpyinfo >/dev/null 2>&1; then
    warn "Cannot reach X display ${VIEWER_DISPLAY}; disabling the live viewer."
    warn "  Pass --viewer-display :N if the desktop is on another display."
    DISPLAY_DATA=false
    return 0
  fi

  info "Live viewer will open on display ${VIEWER_DISPLAY}"
}

# ---------------------------------------------------------------------------
# CAN
# ---------------------------------------------------------------------------

list_can_interfaces() {
  local candidate_path
  shopt -s nullglob
  for candidate_path in /sys/class/net/can*; do
    printf '  %s -> %s\n' "$(basename "${candidate_path}")" "$(readlink -f "${candidate_path}/device")"
  done
  shopt -u nullglob
}

can_iface_is_usb() {
  [[ -e "/sys/class/net/$1/device" ]] || return 1
  [[ "$(readlink -f "/sys/class/net/$1/device")" == *usb* ]]
}

# Prints the interface name, or nothing when none is present. Always succeeds:
# callers assign it inside `$(...)`, and during a USB re-enumeration "no CAN
# interface yet" is the expected state, not an error.
detect_can_iface() {
  local candidate candidate_path first_can=""
  shopt -s nullglob
  for candidate_path in /sys/class/net/can*; do
    candidate="$(basename "${candidate_path}")"
    [[ -z "${first_can}" ]] && first_can="${candidate}"
    if can_iface_is_usb "${candidate}"; then
      shopt -u nullglob
      echo "${candidate}"
      return 0
    fi
  done
  shopt -u nullglob
  [[ -n "${first_can}" ]] && echo "${first_can}"
  return 0
}

# Walk up from the netdev to the USB device node that owns it.
can_usb_device_path() {
  local dev
  dev="$(readlink -f "/sys/class/net/$1/device" 2>/dev/null)" || return 1
  while [[ -n "${dev}" && "${dev}" != "/" && "${dev}" != "." ]]; do
    if [[ -f "${dev}/idVendor" && -f "${dev}/authorized" ]]; then
      echo "${dev}"
      return 0
    fi
    dev="$(dirname "${dev}")"
  done
  return 1
}

# De-authorising and re-authorising the USB device makes the kernel tear the
# adapter down and re-enumerate it -- the software equivalent of unplugging it.
# That clears a bus-off / stuck-queue adapter left behind by a hard kill.
reset_can_adapter() {
  local usbdev
  if ! usbdev="$(can_usb_device_path "${CAN_IFACE}")"; then
    warn "${CAN_IFACE} is not a USB adapter; skipping the USB reset"
    return 0
  fi

  info "Power-cycling the USB-CAN adapter at $(basename "${usbdev}")"
  sudo ip link set "${CAN_IFACE}" down 2>/dev/null || true
  echo 0 | sudo tee "${usbdev}/authorized" >/dev/null
  sleep 1
  echo 1 | sudo tee "${usbdev}/authorized" >/dev/null

  # Re-enumeration can hand the adapter a different canX index.
  local waited=0 detected=""
  while (( waited < 15 )); do
    sleep 1
    waited=$((waited + 1))
    detected="$(detect_can_iface)"
    if [[ -n "${detected}" ]] && can_iface_is_usb "${detected}"; then
      break
    fi
    detected=""
  done

  [[ -n "${detected}" ]] || fail "The USB-CAN adapter did not come back after the reset; replug it manually"
  if [[ "${detected}" != "${CAN_IFACE}" ]]; then
    info "CAN interface renamed after re-enumeration: ${CAN_IFACE} -> ${detected}"
    CAN_IFACE="${detected}"
  fi
}

setup_can() {
  echo "CAN interfaces:"
  list_can_interfaces || true

  local auto_selected=false
  if [[ "${CAN_IFACE}" == "auto" ]]; then
    CAN_IFACE="$(detect_can_iface)"
    auto_selected=true
  fi

  [[ -n "${CAN_IFACE}" ]] || fail "No canX interface was detected"
  [[ -e "/sys/class/net/${CAN_IFACE}" ]] || fail "CAN interface does not exist: ${CAN_IFACE}"

  if [[ "${auto_selected}" == "true" ]] && ! can_iface_is_usb "${CAN_IFACE}"; then
    fail "Auto-detect only found the onboard CAN controller, not the USB adapter used by teleop. Reconnect the adapter or pass --can canX."
  fi

  [[ "${CAN_USB_RESET}" == "true" ]] && reset_can_adapter

  info "Configuring ${CAN_IFACE} at ${CAN_BITRATE} bit/s"
  sudo ip link set "${CAN_IFACE}" down 2>/dev/null || true
  sudo ip link set "${CAN_IFACE}" type can bitrate "${CAN_BITRATE}" restart-ms "${CAN_RESTART_MS}"
  sudo ip link set "${CAN_IFACE}" txqueuelen 1000
  sudo ip link set "${CAN_IFACE}" up
  CAN_CONFIGURED="true"
  ip -details -statistics link show "${CAN_IFACE}" | sed 's/^/  /'
}

# The CAN controller state, e.g. ERROR-ACTIVE (healthy) or BUS-OFF (needs a
# link bounce). Deliberately matches only the controller states so it never
# picks up the "state UP" of the netdev line.
can_state() {
  ip -details link show "${CAN_IFACE}" 2>/dev/null \
    | grep -oE 'state (ERROR-ACTIVE|ERROR-WARNING|ERROR-PASSIVE|BUS-OFF|STOPPED|SLEEPING)' \
    | head -1 | awk '{print $2}'
}

# ---------------------------------------------------------------------------
# Shutdown safety
# ---------------------------------------------------------------------------

# lerobot-record homes the arm and drops torque in its own `finally` block. This
# is the backstop for the cases where it never got there (SIGKILL, OOM, a crash
# inside the SDK) and the motors would otherwise stay energised on the bus.
safe_stop_motors() {
  [[ "${CAN_CONFIGURED}" == "true" ]] || return 0
  python - "${CAN_IFACE}" <<'PY' 2>/dev/null || true
import sys

from motorbridge import Controller

from lerobot_robot_seeed_b601.config_seeed_b601_rs_follower import SeeedB601RSFollowerConfig
from lerobot_robot_seeed_b601.seeed_b601_rs_follower import SeeedB601RSFollower

config = SeeedB601RSFollowerConfig(port=sys.argv[1])
bus = Controller(channel=config.port)
motors = []
try:
    for name, (send_id, recv_id) in config.motor_can_ids.items():
        motors.append(bus.add_robstride_motor(send_id, recv_id, SeeedB601RSFollower.motor_model_mapping[name]))
    bus.disable_all()
finally:
    for motor in motors:
        try:
            motor.close()
        except Exception:
            pass
    try:
        bus.close()
    except Exception:
        pass
PY
}

can_down() {
  [[ "${CAN_CONFIGURED}" == "true" ]] || return 0
  sudo -n ip link set "${CAN_IFACE}" down 2>/dev/null \
    || sudo ip link set "${CAN_IFACE}" down 2>/dev/null \
    || warn "Could not bring ${CAN_IFACE} down; run: sudo ip link set ${CAN_IFACE} down"
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP

  # lerobot-record runs in the foreground, so it has already exited (and run its
  # own homing + torque-off) by the time bash gets here. Catch any stragglers --
  # but only if this run actually launched one, otherwise an early abort (for
  # instance the "already recording" guard) would kill another session's job.
  if [[ "${RECORDER_STARTED}" == "true" ]]; then
    local orphan
    orphan="$(pgrep -u "$(id -u)" -f '(^|/)lerobot-record( |$)' || true)"
    if [[ -n "${orphan}" ]]; then
      info "Waiting for lerobot-record to stop cleanly..."
      # shellcheck disable=SC2086 - pgrep returns a whitespace-separated PID list
      kill -INT ${orphan} 2>/dev/null || true
      local waited=0
      while pgrep -u "$(id -u)" -f '(^|/)lerobot-record( |$)' >/dev/null 2>&1 && (( waited < 60 )); do
        sleep 1
        waited=$((waited + 1))
      done
      pkill -u "$(id -u)" -TERM -f '(^|/)lerobot-record( |$)' 2>/dev/null || true
    fi
  fi

  info "Making the arm safe and releasing the CAN bus"
  safe_stop_motors
  can_down
  exit "${status}"
}

# ---------------------------------------------------------------------------
# Dataset
# ---------------------------------------------------------------------------

completed_episodes() {
  local info_file="${DATASET_ROOT}/meta/info.json"
  [[ -f "${info_file}" ]] || { echo 0; return; }
  python - "${info_file}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(int(json.load(stream).get("total_episodes", 0)))
PY
}

quarantine_dataset() {
  local reason="$1"
  local backup_path="${DATASET_ROOT}.incomplete.$(date +%Y%m%d-%H%M%S)"
  warn "${reason}"
  info "Moving it to ${backup_path}"
  mv "${DATASET_ROOT}" "${backup_path}"
}

# Resuming into a dataset recorded with a different fps or a different camera
# set fails deep inside lerobot with a DeepDiff dump. Catch it up front and move
# the old dataset aside so a fresh one is created.
prepare_dataset_checkpoint() {
  local info_file="${DATASET_ROOT}/meta/info.json"
  local tasks_file="${DATASET_ROOT}/meta/tasks.parquet"

  [[ -d "${DATASET_ROOT}" ]] || return 0

  if [[ ! -f "${info_file}" ]]; then
    if find "${DATASET_ROOT}" -mindepth 1 -print -quit | grep -q .; then
      quarantine_dataset "Found a dataset directory with no metadata."
    else
      rmdir "${DATASET_ROOT}"
    fi
    return
  fi

  local completed
  completed="$(completed_episodes)"
  if (( completed == 0 )); then
    quarantine_dataset "Found a zero-episode dataset checkpoint."
    return
  fi

  [[ -f "${tasks_file}" ]] \
    || fail "Dataset has ${completed} episode(s) but ${tasks_file} is missing; inspect it before resuming"

  local mismatch
  mismatch="$(
    python - "${info_file}" "${CAMERA_FPS}" $(dataset_image_keys) <<'PY'
import json
import sys

info_file, fps = sys.argv[1], int(sys.argv[2])
wanted = set(sys.argv[3:])

with open(info_file, encoding="utf-8") as stream:
    info = json.load(stream)

problems = []
if int(info.get("fps", 0)) != fps:
    problems.append(f"fps {info.get('fps')} != requested {fps}")

found = {k for k in info.get("features", {}) if k.startswith("observation.images.")}
if found != wanted:
    problems.append(
        f"cameras {sorted(found) or ['none']} != requested {sorted(wanted) or ['none']}"
    )

print("; ".join(problems))
PY
  )"

  if [[ -n "${mismatch}" ]]; then
    quarantine_dataset "Existing dataset (${completed} episode(s)) does not match this run: ${mismatch}."
    return
  fi

  info "Resuming dataset with ${completed} completed episode(s)"
}

# ---------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------

# One glance at everything this run will and will not capture.
print_capture_plan() {
  local tick=$'\033[32m✓\033[0m'
  local cross=$'\033[31m✗\033[0m'
  local geom="${CAMERA_WIDTH}x${CAMERA_HEIGHT} @${CAMERA_FPS}"
  local entry key label

  echo
  info "Capture plan"

  # CAMERA_PRESENT is only filled in by autodetect_cameras. With an explicit
  # --cameras list (or a caller that sources this file and sets CAMERAS itself)
  # it stays empty, which would silently print a plan with no cameras at all --
  # exactly the detail worth confirming before a run. Derive it from the tokens.
  if [[ ${#CAMERA_PRESENT[@]} -eq 0 && "${CAMERAS}" != "none" ]]; then
    local token
    for token in ${CAMERAS//,/ }; do
      [[ -n "${token}" ]] && CAMERA_PRESENT+=("${token}|explicitly selected")
    done
  fi

  for entry in "${CAMERA_PRESENT[@]}"; do
    [[ -n "${entry}" ]] || continue
    key="${entry%%|*}"
    label="${entry#*|}"
    if [[ "${key}" == *_depth ]]; then
      printf '  %b %-15s %-34s depth  %s  raw uint16 + intrinsics\n' "${tick}" "${key}" "${label}" "${geom}"
    else
      printf '  %b %-15s %-34s RGB    %s\n' "${tick}" "${key}" "${label}" "${geom}"
    fi
  done

  for entry in "${CAMERA_ABSENT[@]}"; do
    [[ -n "${entry}" ]] || continue
    key="${entry%%|*}"
    label="${entry#*|}"
    printf '  %b %-15s %-34s %s\n' "${cross}" "${key}" "${label%%|*}" "${label#*|}"
  done

  printf '  %b %-15s %s\n' "${tick}" "joint state" "7 joints (position) -> observation.state"
  printf '  %b %-15s %s\n' "${tick}" "actions" "7 joints (position) -> action"
  printf '  %b %-15s %s\n' "${tick}" "language task" "\"${TASK}\""
  printf '  %b %-15s %s\n' "${tick}" "timestamps" "timestamp, frame_index, episode_index"

  if [[ "${RECORD_DEPTH}" == "true" ]]; then
    printf '  %b %-15s %s\n' "${tick}" "intrinsics" "meta/depth_info.json (depth aligned to colour)"
  else
    printf '  %b %-15s %s\n' "${cross}" "intrinsics" "no depth stream selected"
  fi
  printf '  %b %-15s %s\n' "${cross}" "extrinsics" \
    "not calibrated - fine for single-camera depth, needed only to fuse cameras"

  if [[ "${DISPLAY_DATA}" == "true" ]]; then
    if [[ -z "${DISPLAY:-}" ]]; then
      printf '  %b %-15s %s\n' "${cross}" "live viewer" \
        "requested but DISPLAY is unset - run from a desktop session, or --no-display"
    else
      printf '  %b %-15s %s\n' "${tick}" "live viewer" "Rerun window (--no-display to disable)"
    fi
  else
    printf '  %b %-15s %s\n' "${cross}" "live viewer" "disabled (--display to enable)"
  fi
  echo
}

initial_countdown() {
  local seconds="${RESET_TIME_S}"
  echo
  echo "Set up the scene. Recording starts in ${seconds} seconds (Ctrl-C to abort)."
  speak "Set up the scene. Recording starts in ${seconds} seconds."
  while (( seconds > 0 )); do
    printf '\r  starting in %2ds... ' "${seconds}"
    sleep 1
    seconds=$((seconds - 1))
  done
  printf '\r  starting now.        \n'
}

run_recording() {
  local already_recorded="$1"
  local remaining=$((TARGET_EPISODES - already_recorded))
  local resume="false"
  [[ -f "${DATASET_ROOT}/meta/info.json" ]] && resume="true"

  local -a record_args=(
    lerobot-record
    "--robot.type=${ROBOT_TYPE}"
    "--robot.port=${CAN_IFACE}"
    "--robot.id=${ROBOT_ID}"
    "--robot.can_adapter=${ROBOT_CAN_ADAPTER}"
    "--robot.cameras=${CAMERA_CONFIG}"
    "--teleop.type=${TELEOP_TYPE}"
    "--teleop.port=${LEADER_PORT}"
    "--teleop.id=${TELEOP_ID}"
    "--display_data=${DISPLAY_DATA}"
    "--play_sounds=true"
    "--dataset.repo_id=${DATASET_REPO_ID}"
    "--dataset.root=${DATASET_ROOT}"
    "--dataset.single_task=${TASK}"
    "--dataset.fps=${CAMERA_FPS}"
    "--dataset.num_episodes=${remaining}"
    "--dataset.episode_time_s=${EPISODE_TIME_S}"
    "--dataset.reset_time_s=${RESET_TIME_S}"
    "--dataset.discard_reset_time_s=${DISCARD_RESET_TIME_S}"
    "--dataset.engage_ramp_s=${ENGAGE_RAMP_S}"
    "--leader_home_tolerance_deg=${LEADER_HOME_TOLERANCE_DEG}"
    "--dataset.push_to_hub=${PUSH_TO_HUB}"
    "--dataset.vcodec=${VIDEO_CODEC}"
    "--resume=${resume}"
  )

  echo
  echo "  Dataset : ${DATASET_REPO_ID}"
  echo "  Path    : ${DATASET_ROOT}"
  echo "  Task    : ${TASK}"
  echo "  Progress: ${already_recorded}/${TARGET_EPISODES} done, recording ${remaining} more"
  echo "  Cameras : ${CAMERAS} @ ${CAMERA_WIDTH}x${CAMERA_HEIGHT} ${CAMERA_FPS} fps"
  if [[ "${RECORD_DEPTH}" == "true" ]]; then
    echo "  Depth   : raw uint16 -> ${DATASET_ROOT}/depth/<key>/episode_NNNNNN.mkv (aligned to colour)"
  fi
  echo "  Episode : $( ((EPISODE_TIME_S > 0)) && echo "${EPISODE_TIME_S}s max" || echo "manual (press RIGHT)" ), reset ${RESET_TIME_S}s"
  echo "  Controls: RIGHT=save  LEFT=discard+redo  ESC=stop cleanly"

  print_capture_plan
  initial_countdown

  # Run in the foreground on purpose. Ctrl-C then reaches lerobot-record
  # directly, and bash defers this script's INT trap until the child has
  # finished homing the arm and dropping torque.
  RECORDER_STARTED="true"
  set +e
  "${record_args[@]}"
  local status=$?
  set -e
  return "${status}"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

# REBOT_LIB_ONLY=true lets another script `source` this file for its proven
# CAN/camera/viewer functions without triggering its argument parsing or main
# flow. Unset (the default), behaviour is unchanged from a normal run.
if [[ "${REBOT_LIB_ONLY:-false}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)             TASK="${2:?missing value for --task}"; shift 2 ;;
    --episodes)         TARGET_EPISODES="${2:?}"; shift 2 ;;
    --episode-seconds)  EPISODE_TIME_S="${2:?}"; shift 2 ;;
    --reset-seconds)    RESET_TIME_S="${2:?}"; shift 2 ;;
    --discard-seconds)  DISCARD_RESET_TIME_S="${2:?}"; shift 2 ;;
    --engage-ramp)      ENGAGE_RAMP_S="${2:?}"; shift 2 ;;
    --leader-home-tolerance) LEADER_HOME_TOLERANCE_DEG="${2:?}"; shift 2 ;;
    --repo-id)          DATASET_REPO_ID="${2:?}"; shift 2 ;;
    --dataset-root)     DATASET_ROOT="${2:?}"; shift 2 ;;
    --cameras)          CAMERAS="${2:?}"; shift 2 ;;
    --fps)              CAMERA_FPS="${2:?}"; shift 2 ;;
    --width)            CAMERA_WIDTH="${2:?}"; shift 2 ;;
    --height)           CAMERA_HEIGHT="${2:?}"; shift 2 ;;
    --orbbec-id)        ORBBEC_ID="${2:?}"; shift 2 ;;
    --d405-serial)      D405_SERIAL="${2:?}"; shift 2 ;;
    --d435i-serial)     D435I_SERIAL="${2:?}"; shift 2 ;;
    --can)              CAN_IFACE="${2:?}"; shift 2 ;;
    --leader)           LEADER_PORT="${2:?}"; shift 2 ;;
    --no-can-reset)     CAN_USB_RESET=false; shift ;;
    --skip-camera-check) CHECK_CAMERAS=false; shift ;;
    --push-to-hub)      PUSH_TO_HUB=true; shift ;;
    --display)          DISPLAY_DATA=true; shift ;;
    --no-display)       DISPLAY_DATA=false; shift ;;
    --viewer-display)   VIEWER_DISPLAY="${2:?}"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "${DATASET_REPO_ID}" == */* ]] || fail "--repo-id must use OWNER/NAME format"
# With --cameras auto the token list does not exist yet; it is validated right
# after autodetection instead.
[[ "${CAMERAS}" == "auto" ]] || validate_camera_tokens
require_positive_integer "--episodes" "${TARGET_EPISODES}"
require_nonnegative_integer "--episode-seconds" "${EPISODE_TIME_S}"
require_positive_integer "--reset-seconds" "${RESET_TIME_S}"
require_positive_integer "--fps" "${CAMERA_FPS}"
require_positive_integer "--width" "${CAMERA_WIDTH}"
require_positive_integer "--height" "${CAMERA_HEIGHT}"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

trap cleanup EXIT INT TERM HUP

activate_conda_env
autodetect_cameras
apply_camera_selection
check_python_environment
check_video_stack
check_no_existing_recording
stop_stale_viewer

check_orbbec_udev_rules
resolve_orbbec_id
check_realsense_devices
check_usb_link_speed
make_camera_config
check_camera_streams

setup_viewer_display
check_leader_port
setup_can

mkdir -p "$(dirname "${DATASET_ROOT}")"
check_disk_space
prepare_dataset_checkpoint

if [[ ! -t 0 ]]; then
  warn "stdin is not a terminal: the RIGHT/LEFT/ESC keys will not work. Use Ctrl-C to stop."
fi

while true; do
  completed="$(completed_episodes)"
  if (( completed >= TARGET_EPISODES )); then
    info "Dataset already has ${completed}/${TARGET_EPISODES} episodes. Nothing to do."
    speak "Dataset collection complete."
    exit 0
  fi

  if run_recording "${completed}"; then
    recording_status=0
  else
    recording_status=$?
  fi

  new_completed="$(completed_episodes)"
  echo
  info "Checkpoint: ${new_completed}/${TARGET_EPISODES} completed episode(s)"

  if (( new_completed >= TARGET_EPISODES )); then
    speak "Dataset collection complete."
    info "Collection complete."
    exit 0
  fi

  if (( recording_status != 0 )); then
    warn "lerobot-record exited with status ${recording_status}; completed episodes remain resumable."
    state="$(can_state || true)"
    [[ -n "${state}" ]] && warn "CAN link is in ${state}"
  else
    info "Stopped cleanly. Rerun this script to resume."
  fi
  speak "Recording stopped. Checkpoint saved."

  if [[ ! -t 0 ]]; then
    exit "${recording_status}"
  fi

  read -r -p "Continue with the remaining $((TARGET_EPISODES - new_completed)) episode(s) now? [y/N] " reply
  case "${reply}" in
    y|Y|yes|YES)
      # Only re-initialise the adapter if the previous run left it unhealthy;
      # a clean stop leaves the link up and ERROR-ACTIVE.
      state="$(can_state || true)"
      if [[ "${state}" != "ERROR-ACTIVE" ]]; then
        warn "CAN controller is '${state:-unknown}'; reinitialising the adapter"
        setup_can
      fi
      continue
      ;;
    *)
      info "Run the same command later to resume from episode ${new_completed}."
      exit "${recording_status}"
      ;;
  esac
done
