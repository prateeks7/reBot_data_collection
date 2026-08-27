#!/usr/bin/env python
"""Download a pi0.5 checkpoint and apply the fixes it needs to run here.

Checkpoints as trained carry two settings that are wrong for inference on this
rig, and one of them cannot be overridden from the command line:

  compile_model=True, compile_mode="max-autotune"
      The async policy server loads the policy with a bare
      `from_pretrained(path)` -- no cli_overrides hook -- so a CLI flag can fix
      sync and leave async recompiling for a very long time on every start.
      It is left True here (the server is long-lived and warms up before the
      robot streams) and `run_inference.sh` passes
      --policy.compile_model=false for sync instead.

  gradient_checkpointing=True
      A training-time memory/compute tradeoff with nothing to offer at
      inference. Turned off.

The original file is kept alongside as config.json.hub-original.

    python inference/fetch_checkpoint.py 40k
    python inference/fetch_checkpoint.py 100k --repo prateeks-iu/pi05_brown_sugar_100k
"""

import argparse
import json
import shutil
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent
DEFAULT_REPO = "prateeks-iu/pi05_brown_sugar_100k"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("name", help="short name, e.g. 40k -- maps to step 040000")
    p.add_argument("--repo", default=DEFAULT_REPO, help=f"Hub repo id (default: {DEFAULT_REPO})")
    p.add_argument("--step", help="explicit zero-padded step dir, e.g. 040000 (default: derived from name)")
    args = p.parse_args()

    step = args.step or f"{int(args.name.rstrip('kK')) * 1000:06d}"
    dest = REPO_DIR / "inference" / f"pi05_brown_sugar_{args.name}"

    from huggingface_hub import HfApi, snapshot_download

    available = sorted({f.split("/")[0] for f in HfApi().list_repo_files(args.repo) if f.split("/")[0].isdigit()})
    if step not in available:
        print(f"step {step} not in {args.repo}. Available: {', '.join(available)}")
        return 1

    print(f"Downloading {args.repo}:{step} -> {dest}")
    snapshot_download(args.repo, allow_patterns=[f"{step}/*"], local_dir=str(dest), max_workers=4)

    cfg_path = dest / step / "pretrained_model" / "config.json"
    if not cfg_path.exists():
        print(f"expected config at {cfg_path}")
        return 1

    backup = cfg_path.with_suffix(".json.hub-original")
    if not backup.exists():
        shutil.copy(cfg_path, backup)

    cfg = json.loads(cfg_path.read_text())
    before = (cfg.get("compile_model"), cfg.get("gradient_checkpointing"))
    cfg["compile_model"] = True
    cfg["gradient_checkpointing"] = False
    cfg_path.write_text(json.dumps(cfg, indent=4))

    print(f"\ncompile_model/gradient_checkpointing: {before} -> (True, False)")
    print(f"  compile_mode        : {cfg.get('compile_mode')!r}")
    print(f"  chunk_size          : {cfg.get('chunk_size')}")
    print(f"  n_action_steps      : {cfg.get('n_action_steps')}")
    print(f"  dtype               : {cfg.get('dtype')}")
    print(f"  use_relative_actions: {cfg.get('use_relative_actions')}")
    print(f"  inputs              : {list(cfg.get('input_features', {}))}")
    print(f"\nRun it with:\n  inference/run_inference.sh --checkpoint {args.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
