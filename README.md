# reBot B601-RS — VLA data collection

Teleop data-collection tooling for the reBot B601-RS arm, producing LeRobot v3
datasets used to train pi0.5 / PointVLA policies.

Rig: NVIDIA Jetson Thor (aarch64), conda env `rs`. RealSense D405 on the wrist,
RealSense D435i overhead, both 640x480 @ 30 fps over USB 3.2. Leader arm on
`/dev/ttyUSB0`; follower on CAN at 1 Mbit/s via a PEAK USB-CAN adapter (`can4`).

## Contents

| Path | What it is |
|---|---|
| `record_rebot_vla.sh` | The data-collection launcher. CAN bring-up, camera validation, resumable recording. |
| `inference/fetch_checkpoint.py` | Download a pi0.5 checkpoint and apply the config fixes it needs to run. |
| `inference/run_inference.sh` | Run a checkpoint on the arm, sync (records) or async (does not). |
| `inference/go_home.py` | Standalone motor fault check + verified ramp to home. |
| `inference/start_async_server.sh` | Homes the arm, gates on motor health, starts the async policy server. |
| `push_to_hub.py` | Push a finished dataset (including the depth sidecar) to the Hugging Face Hub. |
| `read_depth.py` | Read the raw uint16 depth sidecar back out. |
| `merge_rebot_datasets.py` | Merge several recorded datasets into one. |
| `preview_pi05_input.py` | Render what a pi0.5 policy actually sees for a given frame. |
| `run_lerobot_auto_can.sh`, `helpful_docs/` | CAN debugging notes and helpers. |
| `calibration/` | Leader and follower calibration files, plus what they do and do not contain. |
| `lerobot_patches/` | Our changes to the LeRobot fork (see below). |

## Calibration

```bash
cp -r calibration/robots         ~/.cache/huggingface/lerobot/calibration/
cp -r calibration/teleoperators  ~/.cache/huggingface/lerobot/calibration/
```

Note these do **not** carry the arm's zero position — that lives in each
RobStride motor's non-volatile memory, written by `set_zero_position()`. The
committed files hold placeholder ranges only, so LeRobot does not prompt for a
fresh calibration on connect. See `calibration/README.md`.

## Recording

```bash
./record_rebot_vla.sh --episodes 200 --cameras wrist,wrist_depth,overhead,overhead_depth
```

`--episodes` is a **target total**, not a per-run count: the script detects an
existing `meta/info.json`, resumes, and records only the remainder. It refuses to
resume into a dataset whose fps or camera key set differs, quarantining rather
than corrupting it.

Controls: `RIGHT`/`Enter` save, `LEFT` discard and redo, `ESC` save and stop
(resumable), `Ctrl-C` same as ESC.

### Homing between episodes

Every episode starts from the same pose. Because teleop is absolute (the
follower mirrors the leader's joint angles), parking the follower is not
sufficient on its own, so the sequence is:

1. The follower ramps to home (all joints 0) over ~3 s.
2. Teleop is **disengaged** for the reset countdown, so the arm stays parked
   while the scene is reset. Without this, the next control tick would mirror
   the leader and undo the homing immediately.
3. Recording starts with the follower still at home — so frame 0 of every
   episode is the same pose.
4. The first `--engage-ramp` seconds blend the follower from home onto the live
   leader pose, then normal teleoperation. That lead-in is part of the episode.

The same homing runs before the *first* episode and after a discarded one, not
just between saved episodes.

`--leader-home-tolerance D` optionally holds until the leader itself is within
D degrees of home before starting (0 = off, the default).

## Inference

```bash
# Fetch a checkpoint (applies the compile_model / gradient_checkpointing fixes)
python inference/fetch_checkpoint.py 40k

# Sync: drives the arm AND records an eval dataset
inference/run_inference.sh --checkpoint 40k

# Async: policy server in one terminal, client in another. Records NOTHING.
inference/start_async_server.sh
inference/run_inference.sh --checkpoint 40k --mode async
```

Only `wrist` and `overhead` RGB are opened -- those are the policy's actual
inputs. The depth streams are recorded during collection but are not policy
inputs, and pi0.5 pads the third camera slot itself (`empty_cameras: 1`).

Two settings matter and are easy to get wrong:

- **`max_relative_target`** defaults to `None` on this robot, which skips
  `ensure_safe_goal_position` entirely, so a policy action is commanded at full
  travel in one tick. `run_inference.sh` sets it to `5.0` degrees per step.
- **`compile_model`** is left `True` in the checkpoint config because the async
  policy server calls `from_pretrained(path)` with no override hook. Sync passes
  `--policy.compile_model=false` so short runs skip the `max-autotune` compile.
  Set `TORCHINDUCTOR_CACHE_DIR` to something persistent (`start_async_server.sh`
  does) or the compile is re-paid on every reboot.

The async client has **no dataset support at all** -- `RobotClientConfig` has no
repo, root, or record field. Use sync if you want the rollouts saved.

## Depth

Adding a `*_depth` camera token records two things: a pseudo-colour preview into
the dataset as an ordinary video stream, **and** the sensor's raw uint16 depth to
`<dataset>/depth/<key>/episode_*.mkv` (FFV1 gray16le, lossless), with scale and
intrinsics in `meta/depth_info.json`. Depth is aligned to colour on-device.

The pseudo-colour preview is *not* usable depth — read the sidecar with
`read_depth.py`.

## lerobot_patches/

The homing, reset, and depth-recording behaviour lives in our LeRobot fork, not
in this repo. `lerobot-data-collection-and-homing.patch` captures those changes
so they are reviewable and reproducible without vendoring the whole fork.

```bash
cd /path/to/lerobot
git checkout $(cat lerobot_patches/BASE_COMMIT.txt)
git apply /path/to/lerobot_patches/lerobot-data-collection-and-homing.patch
cp lerobot_patches/new_files/depth_recorder.py            src/lerobot/datasets/
cp lerobot_patches/new_files/relative_action_processor.py src/lerobot/processor/
```

Main changes:

- `utils/robot_utils.py` — `return_robot_to_home`, `ramp_robot_to_action`, and
  pose reading in action space. A failed feedback read is never substituted with
  `0.0`, because `0.0` *is* home and that would collapse the ramp into a single
  full-travel step.
- `scripts/lerobot_record.py` — homing before the first episode, after a saved
  episode, and after a discarded one; teleop disengaged during reset; the
  recorded `engage_ramp_s` lead-in.
- `datasets/lerobot_dataset.py` — `clear_episode_buffer` sweeps `camera_keys`
  rather than `image_keys`. In a video-only dataset `image_keys` is empty, so
  discarded takes left their staged PNGs on disk to be picked up by the encoder
  when the same episode index was recorded again.
- `datasets/depth_recorder.py` — the raw uint16 depth sidecar.
- `async_inference/robot_client.py` — homes the arm after the gRPC handshake,
  before any observation is streamed.
