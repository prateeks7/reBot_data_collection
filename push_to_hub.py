#!/usr/bin/env python
"""Push a completed reBot dataset to the Hugging Face Hub.

`record_rebot_vla.sh --push-to-hub` only pushes when it finishes the *last*
recording session in-process; a dataset that already hit its episode target
exits before ever reaching that code. This is the standalone equivalent for
a dataset you're done recording.

Depth is not a special case here: `LeRobotDataset.push_to_hub` uploads
everything under the dataset root except `images/` (raw pre-encode frames)
and, if you pass --no-videos, `videos/`. Since `depth/` matches neither, it
rides along in the same upload -- no extra flag needed. What it does NOT do
is mention depth on the auto-generated dataset card, since depth isn't part
of the standard LeRobot schema; this script appends a short section for that
after the push.

Usage:
    python push_to_hub.py datasets/rebot_b601_rs_vla --repo-id you/rebot_b601_rs_vla --private
    python push_to_hub.py datasets/rebot_b601_rs_vla --repo-id you/rebot_b601_rs_vla --public
"""

import argparse
import json
from pathlib import Path


def dir_size_bytes(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def human(num_bytes: int) -> str:
    value = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024:
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} PB"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dataset_root")
    parser.add_argument("--repo-id", required=True, help="e.g. your-username/rebot_b601_rs_vla")
    visibility = parser.add_mutually_exclusive_group(required=True)
    visibility.add_argument("--private", action="store_true", help="upload to a private repo")
    visibility.add_argument("--public", action="store_true", help="upload to a public repo")
    parser.add_argument("--license", default="apache-2.0")
    parser.add_argument("--tags", nargs="*", default=["robotics", "lerobot", "vla"])
    parser.add_argument("--no-videos", action="store_true", help="skip the RGB video files (rarely what you want)")
    parser.add_argument(
        "--resumable",
        action="store_true",
        help=(
            "Use upload_large_folder instead of a single-commit upload. Slower to start "
            "(it hashes every file first) but safe to Ctrl-C and rerun on a bad connection "
            "-- already-uploaded files are skipped. Recommended over a weak/slow link."
        ),
    )
    parser.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    args = parser.parse_args()

    root = Path(args.dataset_root)
    info_path = root / "meta" / "info.json"
    if not info_path.exists():
        raise SystemExit(f"Not a LeRobot dataset (missing {info_path})")

    info = json.loads(info_path.read_text())
    depth_dir = root / "depth"
    depth_streams = sorted(p.name for p in depth_dir.iterdir()) if depth_dir.is_dir() else []

    print(f"Repo       : {args.repo_id}  ({'private' if args.private else 'PUBLIC'})")
    print(f"Root       : {root}")
    print(f"Episodes   : {info.get('total_episodes')}  ({info.get('total_frames')} frames @ {info.get('fps')} fps)")
    print(f"Videos     : {human(dir_size_bytes(root / 'videos'))}" if (root / "videos").is_dir() else "Videos     : none")
    if depth_streams:
        print(f"Depth      : {human(dir_size_bytes(depth_dir))} across {', '.join(depth_streams)} (uploaded automatically)")
    else:
        print("Depth      : none recorded")
    print(f"Total size : {human(dir_size_bytes(root))}")

    if not args.yes:
        reply = input("\nProceed with upload? [y/N] ").strip().lower()
        if reply not in ("y", "yes"):
            print("Aborted.")
            return

    from lerobot.datasets.lerobot_dataset import LeRobotDataset

    dataset = LeRobotDataset(args.repo_id, root=root)
    dataset.push_to_hub(
        tags=args.tags,
        license=args.license,
        private=args.private,
        push_videos=not args.no_videos,
        upload_large_folder=args.resumable,
    )
    print(f"\nPushed to https://huggingface.co/datasets/{args.repo_id}")

    if depth_streams:
        _append_depth_section(args.repo_id, depth_streams, info)


def _append_depth_section(repo_id: str, depth_streams: list[str], info: dict) -> None:
    """Document the depth sidecar on the repo page; push_to_hub's card doesn't know about it."""
    from huggingface_hub import HfApi, hf_hub_download

    api = HfApi()
    try:
        readme_path = hf_hub_download(repo_id=repo_id, repo_type="dataset", filename="README.md")
        readme = Path(readme_path).read_text()
    except Exception as e:  # noqa: BLE001 - card is a nice-to-have, never block on it
        print(f"note: could not fetch the pushed README to append depth docs: {e}")
        return

    depth_scales = ", ".join(
        f"`{key}`: {info.get('features', {}).get(f'observation.images.{key}', {}).get('info', {}).get('video.height', '?')}px"
        for key in depth_streams
    )
    section = f"""

## Depth (RGB-D)

This dataset includes raw metric depth alongside the RGB videos above, for
{", ".join(sorted({s.removesuffix("_depth") for s in depth_streams}))}. It is
**not** part of the standard LeRobot schema, so generic loaders will not see
it automatically.

```
depth/<camera>_depth/episode_NNNNNN.mkv   FFV1, gray16le, lossless uint16
meta/depth_info.json                      depth_scale_m + intrinsics per camera
```

Depth is aligned to its colour camera on capture, so `depth[y, x]` and the
matching `observation.images.<camera>[y, x]` are the same physical point.
`metres = pixel_value * depth_scale_m`; `0` means no return.

Read it with `read_depth.py` from the collection tooling used to record this
dataset, or directly:

```python
import av, json, numpy as np
info = json.load(open("meta/depth_info.json"))
with av.open("depth/wrist_depth/episode_000000.mkv") as c:
    depth = np.stack([f.to_ndarray() for f in c.decode(video=0)])
depth_m = depth.astype(np.float32) * info["cameras"]["wrist_depth"]["depth_scale_m"]
```
"""
    api.upload_file(
        path_or_fileobj=(readme + section).encode(),
        path_in_repo="README.md",
        repo_id=repo_id,
        repo_type="dataset",
    )
    print("Appended a depth section to the dataset card.")


if __name__ == "__main__":
    main()
