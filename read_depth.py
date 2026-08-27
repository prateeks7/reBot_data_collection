#!/usr/bin/env python
"""Read the raw depth recorded alongside a reBot LeRobot dataset.

    from read_depth import load_episode_depth, depth_to_point_cloud

    depth_m, calib = load_episode_depth("datasets/rebot_b601_rs_vla", "wrist_depth", 0)
    xyz, mask = depth_to_point_cloud(depth_m[0], calib)

CLI:
    python read_depth.py <dataset_root> [--key wrist_depth] [--episode 0] [--export-png OUTDIR]
"""

import argparse
import json
from pathlib import Path

import av
import numpy as np


def load_depth_info(dataset_root: Path | str) -> dict:
    """Depth scale and intrinsics for every recorded depth stream."""
    with open(Path(dataset_root) / "meta" / "depth_info.json", encoding="utf-8") as stream:
        return json.load(stream)


def load_episode_depth(
    dataset_root: Path | str, key: str, episode_index: int
) -> tuple[np.ndarray, dict]:
    """Return (T, H, W) float32 depth in **metres** plus that camera's calibration.

    Frame t lines up with row t of the episode in the LeRobot parquet, and with
    the matching colour video, so `depth[t][y, x]` and `rgb[t][y, x]` are the
    same point. Zero means the sensor returned nothing there.
    """
    dataset_root = Path(dataset_root)
    info = load_depth_info(dataset_root)
    calibration = info["cameras"][key]

    path = dataset_root / "depth" / key / f"episode_{episode_index:06d}.mkv"
    if not path.exists():
        raise FileNotFoundError(f"No depth recorded for '{key}' episode {episode_index}: {path}")

    with av.open(str(path)) as container:
        frames = np.stack([frame.to_ndarray() for frame in container.decode(video=0)])

    return frames.astype(np.float32) * float(calibration["depth_scale_m"]), calibration


def depth_to_point_cloud(
    depth_m: np.ndarray,
    calibration: dict,
    min_m: float = 0.05,
    max_m: float = 2.0,
) -> tuple[np.ndarray, np.ndarray]:
    """Unproject one (H, W) metric depth frame to an (N, 3) cloud in camera coords.

    Returns `(points, valid_mask)`. Because depth is aligned to colour, per-point
    colour is just `rgb[valid_mask]` for the matching RGB frame. Axes use the
    usual camera convention: +X right, +Y down, +Z forward, in metres.
    """
    intrinsics = calibration["intrinsics"]
    height, width = depth_m.shape
    if (intrinsics["height"], intrinsics["width"]) != (height, width):
        raise ValueError(
            f"Intrinsics are for {intrinsics['width']}x{intrinsics['height']} but the depth frame "
            f"is {width}x{height}."
        )

    rows, cols = np.mgrid[0:height, 0:width]
    valid = (depth_m > min_m) & (depth_m < max_m)
    z = depth_m[valid]
    x = (cols[valid] - intrinsics["cx"]) * z / intrinsics["fx"]
    y = (rows[valid] - intrinsics["cy"]) * z / intrinsics["fy"]
    return np.stack([x, y, z], axis=-1), valid


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dataset_root")
    parser.add_argument("--key", default=None, help="depth stream (default: the first one recorded)")
    parser.add_argument("--episode", type=int, default=0)
    parser.add_argument("--export-png", metavar="OUTDIR", help="also write uint16 PNGs, one per frame")
    args = parser.parse_args()

    info = load_depth_info(args.dataset_root)
    key = args.key or next(iter(info["cameras"]))
    depth_m, calibration = load_episode_depth(args.dataset_root, key, args.episode)

    valid = depth_m[depth_m > 0]
    print(f"{key} episode {args.episode}: {depth_m.shape[0]} frames of {depth_m.shape[2]}x{depth_m.shape[1]}")
    print(f"  depth_scale_m       : {calibration['depth_scale_m']}")
    print(f"  aligned to colour   : {calibration['depth_aligned_to_color']}")
    print(f"  intrinsics          : {calibration['intrinsics']}")
    if valid.size:
        print(f"  metric range        : {valid.min():.3f} - {valid.max():.3f} m")
        print(f"  valid pixels        : {(depth_m > 0).mean():.1%}")

    points, _ = depth_to_point_cloud(depth_m[0], calibration)
    print(f"  frame 0 point cloud : {len(points)} points")

    if args.export_png:
        import cv2

        out_dir = Path(args.export_png)
        out_dir.mkdir(parents=True, exist_ok=True)
        raw = np.round(depth_m / float(calibration["depth_scale_m"])).astype(np.uint16)
        for index, frame in enumerate(raw):
            cv2.imwrite(str(out_dir / f"{index:06d}.png"), frame)
        print(f"  wrote {len(raw)} uint16 PNGs to {out_dir}")


if __name__ == "__main__":
    main()
