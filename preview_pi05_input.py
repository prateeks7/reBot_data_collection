#!/usr/bin/env python
"""Show what a pi0/pi0.5 policy actually sees from a recorded LeRobot dataset.

openpi feeds every camera through `image_tools.resize_with_pad(img, 224, 224)`
before the vision-language backbone (PaliGemma) ever sees it. That is NOT a
crop: it's an aspect-ratio-preserving resize down to fit inside 224x224, then
the shorter side is padded with black to fill the square. Source:
https://github.com/Physical-Intelligence/openpi/blob/main/src/openpi/shared/image_tools.py

This script re-implements that exact algorithm (ratio, rounding, and padding
split all match the original) with OpenCV instead of jax/torch, so it runs
without pulling in either, and renders side-by-side before/after frames.
"""

import argparse
from pathlib import Path

import cv2
import numpy as np


def resize_with_pad(image: np.ndarray, height: int, width: int) -> np.ndarray:
    """Bit-for-bit port of openpi's `resize_with_pad` (jax/torch) to OpenCV.

    Same ratio computation, same integer rounding, same pad split (floor on
    top/left, remainder on bottom/right), same black (zero) fill.
    """
    cur_height, cur_width = image.shape[:2]
    ratio = max(cur_width / width, cur_height / height)
    resized_height = int(cur_height / ratio)
    resized_width = int(cur_width / ratio)

    resized = cv2.resize(image, (resized_width, resized_height), interpolation=cv2.INTER_LINEAR)

    pad_h0, remainder_h = divmod(height - resized_height, 2)
    pad_h1 = pad_h0 + remainder_h
    pad_w0, remainder_w = divmod(width - resized_width, 2)
    pad_w1 = pad_w0 + remainder_w

    return cv2.copyMakeBorder(resized, pad_h0, pad_h1, pad_w0, pad_w1, cv2.BORDER_CONSTANT, value=0)


def read_frames(video_path: Path, indices: list[int]) -> dict[int, np.ndarray]:
    cap = cv2.VideoCapture(str(video_path))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    frames = {}
    for index in indices:
        index = max(0, min(index, total - 1))
        cap.set(cv2.CAP_PROP_POS_FRAMES, index)
        ok, frame = cap.read()
        if ok:
            frames[index] = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    cap.release()
    return frames


def make_comparison(original: np.ndarray, processed: np.ndarray, model_size: int) -> np.ndarray:
    """Original (scaled to a fixed display height) next to what the model sees."""
    display_h = 320
    scale = display_h / original.shape[0]
    original_disp = cv2.resize(original, (int(original.shape[1] * scale), display_h))
    processed_disp = cv2.resize(
        processed, (int(display_h * model_size / model_size), display_h), interpolation=cv2.INTER_NEAREST
    )
    gap = np.full((display_h, 12, 3), 30, dtype=np.uint8)
    return np.hstack([original_disp, gap, processed_disp])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset_root")
    parser.add_argument("--episode", type=int, default=0)
    parser.add_argument("--model-size", type=int, default=224, help="pi0/pi0.5 default is 224")
    parser.add_argument("--out-dir", default="pi05_preview")
    args = parser.parse_args()

    dataset_root = Path(args.dataset_root)
    video_dir = dataset_root / "videos"
    camera_keys = sorted(p.name for p in video_dir.iterdir() if p.is_dir())

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    for camera_key in camera_keys:
        video_path = next((video_dir / camera_key / f"chunk-000").glob(f"file-{args.episode:03d}.mp4"), None)
        if video_path is None:
            print(f"skip {camera_key}: no video for episode {args.episode}")
            continue

        cap = cv2.VideoCapture(str(video_path))
        total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        cap.release()
        indices = sorted({0, total // 2, max(total - 1, 0)})

        frames = read_frames(video_path, indices)
        for index, frame in frames.items():
            processed = resize_with_pad(frame, args.model_size, args.model_size)
            comparison = make_comparison(frame, processed, args.model_size)

            label = camera_key.replace("observation.images.", "")
            comparison_bgr = cv2.cvtColor(comparison, cv2.COLOR_RGB2BGR)
            out_path = out_dir / f"{label}_frame{index:04d}_original_vs_pi05_input.png"
            cv2.imwrite(str(out_path), comparison_bgr)
            print(f"wrote {out_path}  (source {frame.shape[1]}x{frame.shape[0]} -> {args.model_size}x{args.model_size})")


if __name__ == "__main__":
    main()
