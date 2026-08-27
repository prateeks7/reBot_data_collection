#!/usr/bin/env python
"""Remove selected episodes, merge two LeRobot datasets, and preserve raw depth."""

from __future__ import annotations

import argparse
import functools
import json
import shutil
from pathlib import Path

from lerobot.datasets import dataset_tools
from lerobot.datasets.aggregate import aggregate_datasets
from lerobot.datasets.lerobot_dataset import LeRobotDataset


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--first-root", type=Path, required=True)
    parser.add_argument("--first-repo-id", required=True)
    parser.add_argument("--first-delete", type=int, required=True)
    parser.add_argument("--second-root", type=Path, required=True)
    parser.add_argument("--second-repo-id", required=True)
    parser.add_argument("--second-delete", type=int, required=True)
    parser.add_argument("--work-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--output-repo-id", required=True)
    parser.add_argument(
        "--reuse-cleaned",
        action="store_true",
        help="Reuse first-clean and second-clean under work-root after an interrupted final merge",
    )
    return parser.parse_args()


def copy_depth_subset(
    source_root: Path,
    destination_root: Path,
    deleted_episode: int,
    output_offset: int,
) -> int:
    """Copy raw depth episodes while making their indices contiguous."""
    source_depth = source_root / "depth"
    if not source_depth.is_dir():
        return 0

    copied = 0
    for stream_dir in sorted(path for path in source_depth.iterdir() if path.is_dir()):
        destination_stream = destination_root / "depth" / stream_dir.name
        destination_stream.mkdir(parents=True, exist_ok=True)

        source_files = sorted(stream_dir.glob("episode_*.mkv"))
        old_indices = [int(path.stem.removeprefix("episode_")) for path in source_files]
        expected = list(range(len(source_files)))
        if old_indices != expected:
            raise ValueError(f"Non-contiguous depth episodes in {stream_dir}: {old_indices}")

        new_local_index = 0
        for source_path, old_index in zip(source_files, old_indices, strict=True):
            if old_index == deleted_episode:
                continue
            new_index = output_offset + new_local_index
            destination_path = destination_stream / f"episode_{new_index:06d}.mkv"
            shutil.copy2(source_path, destination_path)
            new_local_index += 1
            copied += 1

    return copied


def validate_depth(root: Path, total_episodes: int) -> None:
    depth_root = root / "depth"
    if not depth_root.is_dir():
        return

    for stream_dir in sorted(path for path in depth_root.iterdir() if path.is_dir()):
        paths = sorted(stream_dir.glob("episode_*.mkv"))
        indices = [int(path.stem.removeprefix("episode_")) for path in paths]
        if indices != list(range(total_episodes)):
            raise ValueError(
                f"{stream_dir.name} has {len(paths)} non-contiguous depth episodes; "
                f"expected {total_episodes}"
            )


def main() -> None:
    args = parse_args()
    if args.output_root.exists():
        raise SystemExit(f"Refusing to overwrite existing path: {args.output_root}")
    if args.work_root.exists() and not args.reuse_cleaned:
        raise SystemExit(f"Refusing to overwrite existing path: {args.work_root}")

    first = LeRobotDataset(args.first_repo_id, root=args.first_root)
    second = LeRobotDataset(args.second_repo_id, root=args.second_root)

    # The local PyAV build has H.264 but not LeRobot's default SVT-AV1 encoder.
    dataset_tools._copy_and_reindex_videos = functools.partial(  # noqa: SLF001
        dataset_tools._copy_and_reindex_videos,  # noqa: SLF001
        vcodec="h264",
    )

    first_clean_root = args.work_root / "first-clean"
    second_clean_root = args.work_root / "second-clean"
    first_clean_repo_id = f"{args.output_repo_id}-first-clean"
    second_clean_repo_id = f"{args.output_repo_id}-second-clean"
    if args.reuse_cleaned:
        first_clean = LeRobotDataset(first_clean_repo_id, root=first_clean_root)
        second_clean = LeRobotDataset(second_clean_repo_id, root=second_clean_root)
    else:
        args.work_root.mkdir(parents=True)
        first_clean = dataset_tools.delete_episodes(
            first,
            [args.first_delete],
            output_dir=first_clean_root,
            repo_id=first_clean_repo_id,
        )
        second_clean = dataset_tools.delete_episodes(
            second,
            [args.second_delete],
            output_dir=second_clean_root,
            repo_id=second_clean_repo_id,
        )

    # A 1 MB threshold forces every existing source video file to rotate into
    # a separate destination file. This avoids remuxing files with incompatible
    # timestamp histories while retaining LeRobot's metadata remapping.
    aggregate_datasets(
        repo_ids=[first_clean.repo_id, second_clean.repo_id],
        aggr_repo_id=args.output_repo_id,
        roots=[first_clean.root, second_clean.root],
        aggr_root=args.output_root,
        video_files_size_in_mb=1,
    )
    merged = LeRobotDataset(args.output_repo_id, root=args.output_root)

    # These files describe the custom raw-depth sidecar and are not managed by
    # LeRobot's dataset editor.
    for metadata_name in ("depth_info.json",):
        source_path = args.first_root / "meta" / metadata_name
        if source_path.exists():
            shutil.copy2(source_path, args.output_root / "meta" / metadata_name)

    first_count = first.meta.total_episodes - 1
    copy_depth_subset(args.first_root, args.output_root, args.first_delete, 0)
    copy_depth_subset(args.second_root, args.output_root, args.second_delete, first_count)

    expected_episodes = first.meta.total_episodes + second.meta.total_episodes - 2
    if merged.meta.total_episodes != expected_episodes:
        raise ValueError(
            f"Merged dataset has {merged.meta.total_episodes} episodes; expected {expected_episodes}"
        )
    validate_depth(args.output_root, expected_episodes)

    summary = {
        "first_source_episodes": first.meta.total_episodes,
        "first_deleted_episode": args.first_delete,
        "second_source_episodes": second.meta.total_episodes,
        "second_deleted_episode": args.second_delete,
        "merged_episodes": merged.meta.total_episodes,
        "merged_frames": merged.meta.total_frames,
        "output_root": str(args.output_root),
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
