#!/usr/bin/env bash
# Run a trained pi0.5 checkpoint on the reBot B601-RS arm.
#
# Two modes:
#   sync   `lerobot-record` drives the arm AND records an eval dataset.
#   async  the gRPC robot_client drives the arm. Records NOTHING -- the async
#          client has no dataset support at all. Start the policy server first
#          with inference/start_async_server.sh.
#
# Usage:
#   inference/run_inference.sh --checkpoint 40k
#   inference/run_inference.sh --checkpoint 100k --mode async
#   inference/run_inference.sh --checkpoint 50k --episodes 20 --episode-seconds 45
#
# Checkpoints are expected at inference/pi05_brown_sugar_<NAME>/<step>/pretrained_model
# (see fetch_checkpoint.py, which also applies the required config fixes).
set -Eeuo pipefail

REPO_DIR="/home/seeed_pk/Documents/rs"
CONDA_ENV="${CONDA_ENV:-rs}"

MODE="sync"
CHECKPOINT=""
TASK="${TASK:-Pick one sugar cube and put it in the cup}"
FPS="${FPS:-30}"
EPISODES="${EPISODES:-10}"
EPISODE_SECONDS="${EPISODE_SECONDS:-30}"
RESET_SECONDS="${RESET_SECONDS:-10}"
# Policy is trained with chunk_size=50 / n_action_steps=50; executing a fraction
# of each chunk and re-planning is the usual inference setting.
N_ACTION_STEPS="${N_ACTION_STEPS:-20}"
CHUNK_SIZE="${CHUNK_SIZE:-50}"
# Caps each commanded step relative to the arm's present position. Without it
# `ensure_safe_goal_position` is skipped entirely and a policy action is
# commanded at full travel in a single tick -- the arm lurches.
MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-5.0}"
SERVER_ADDRESS="${SERVER_ADDRESS:-localhost:8080}"
DISPLAY_DATA="${DISPLAY_DATA:-true}"

while (($#)); do
  case "$1" in
    --checkpoint)       CHECKPOINT="${2:?}"; shift 2 ;;
    --mode)             MODE="${2:?}"; shift 2 ;;
    --task)             TASK="${2:?}"; shift 2 ;;
    --episodes)         EPISODES="${2:?}"; shift 2 ;;
    --episode-seconds)  EPISODE_SECONDS="${2:?}"; shift 2 ;;
    --reset-seconds)    RESET_SECONDS="${2:?}"; shift 2 ;;
    --n-action-steps)   N_ACTION_STEPS="${2:?}"; shift 2 ;;
    --chunk-size)       CHUNK_SIZE="${2:?}"; shift 2 ;;
    --max-relative-target) MAX_RELATIVE_TARGET="${2:?}"; shift 2 ;;
    --server)           SERVER_ADDRESS="${2:?}"; shift 2 ;;
    --no-display)       DISPLAY_DATA=false; shift ;;
    -h|--help)          sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${CHECKPOINT}" ]] || { echo "--checkpoint is required (e.g. 40k)" >&2; exit 1; }
[[ "${MODE}" == "sync" || "${MODE}" == "async" ]] || { echo "--mode must be sync or async" >&2; exit 1; }

cd "${REPO_DIR}"

# Resolve inference/pi05_brown_sugar_<name>/<step>/pretrained_model without
# hardcoding the zero-padded step number.
CKPT_ROOT="inference/pi05_brown_sugar_${CHECKPOINT}"
[[ -d "${CKPT_ROOT}" ]] || { echo "no such checkpoint dir: ${CKPT_ROOT}" >&2; exit 1; }
mapfile -t FOUND < <(find "${CKPT_ROOT}" -mindepth 2 -maxdepth 2 -type d -name pretrained_model)
((${#FOUND[@]} == 1)) || {
  echo "expected exactly one pretrained_model under ${CKPT_ROOT}, found ${#FOUND[@]}" >&2
  printf '  %s\n' "${FOUND[@]}" >&2
  exit 1
}
CKPT="${REPO_DIR}/${FOUND[0]#./}"
[[ -f "${CKPT}/config.json" ]] || { echo "no config.json in ${CKPT}" >&2; exit 1; }

# shellcheck disable=SC1091
source ~/miniforge3/etc/profile.d/conda.sh
conda activate "${CONDA_ENV}"

echo "==> Bringing up CAN"
REBOT_LIB_ONLY=true source ./record_rebot_vla.sh
setup_can

# Only the cameras the policy actually consumes. The depth streams are not
# policy inputs -- pi0.5 was trained on wrist + overhead RGB only.
CAMERAS="wrist,overhead"
make_camera_config

LOG="/tmp/${MODE}_${CHECKPOINT}.log"
echo
echo "  Mode       : ${MODE}"
echo "  Checkpoint : ${CKPT}"
echo "  CAN        : ${CAN_IFACE}"
echo "  Task       : ${TASK}"
echo "  Chunking   : n_action_steps=${N_ACTION_STEPS} of chunk_size=${CHUNK_SIZE}"
echo "  Safety     : max_relative_target=${MAX_RELATIVE_TARGET}"
echo "  Log        : ${LOG}"
echo

if [[ "${MODE}" == "sync" ]]; then
  # compile_model is left true in config.json for the async server, which has no
  # CLI override. Sync overrides it off so short runs skip max-autotune compile.
  exec > >(tee "${LOG}") 2>&1
  lerobot-record \
    --robot.type=seeed_b601_rs_follower \
    --robot.port="${CAN_IFACE}" \
    --robot.id=follower1 \
    --robot.can_adapter=socketcan \
    --robot.max_relative_target="${MAX_RELATIVE_TARGET}" \
    --robot.cameras="${CAMERA_CONFIG}" \
    --policy.path="${CKPT}" \
    --policy.compile_model=false \
    --policy.n_action_steps="${N_ACTION_STEPS}" \
    --policy.chunk_size="${CHUNK_SIZE}" \
    --policy.device=cuda \
    --dataset.repo_id="prateeks-iu/eval_pi05_brown_sugar_${CHECKPOINT}" \
    --dataset.root="datasets/eval_pi05_brown_sugar_${CHECKPOINT}" \
    --dataset.single_task="${TASK}" \
    --dataset.fps="${FPS}" \
    --dataset.num_episodes="${EPISODES}" \
    --dataset.episode_time_s="${EPISODE_SECONDS}" \
    --dataset.reset_time_s="${RESET_SECONDS}" \
    --dataset.push_to_hub=false \
    --dataset.vcodec=h264 \
    --display_data="${DISPLAY_DATA}"
else
  echo "  NOTE: async records no dataset. Use --mode sync for eval episodes."
  echo "  Server must already be running: inference/start_async_server.sh"
  echo
  exec > >(tee "${LOG}") 2>&1
  python -m lerobot.async_inference.robot_client \
    --server_address="${SERVER_ADDRESS}" \
    --policy_type=pi05 \
    --pretrained_name_or_path="${CKPT}" \
    --policy_device=cuda \
    --robot.type=seeed_b601_rs_follower \
    --robot.port="${CAN_IFACE}" \
    --robot.id=follower1 \
    --robot.can_adapter=socketcan \
    --robot.max_relative_target="${MAX_RELATIVE_TARGET}" \
    --robot.cameras="${CAMERA_CONFIG}" \
    --actions_per_chunk="${N_ACTION_STEPS}" \
    --chunk_size_threshold=0.5 \
    --aggregate_fn_name=weighted_average \
    --task="${TASK}" \
    --fps="${FPS}"
fi
