"""Sidecar recorder for raw metric depth.

LeRobot's image/video path is hardcoded to 3-channel uint8 (see
`image_writer.image_array_to_pil_image`), so a depth camera can only enter a
dataset as an 8-bit colour map -- fine to look at, useless as depth. This module
stores the sensor's uint16 depth losslessly alongside the dataset instead.

Layout, mirroring the dataset's own `videos/<key>/` layout::

    <dataset_root>/depth/<key>/episode_000000.mkv   FFV1, gray16le, lossless
    <dataset_root>/meta/depth_info.json             scale + intrinsics per key

Metres are `pixel_value * depth_scale_m`; 0 means "no return". Depth is aligned
to its colour camera at capture time, so `depth[y, x]` and `rgb[y, x]` are the
same point and unprojection needs only the shared intrinsics.

Reading one back::

    import av, numpy as np
    with av.open("depth/wrist/episode_000000.mkv") as c:
        depth = np.stack([f.to_ndarray() for f in c.decode(video=0)])  # (T, H, W) uint16
"""

import json
import logging
import queue
import shutil
import threading
from pathlib import Path
from typing import Any

import av
import numpy as np

logger = logging.getLogger(__name__)

DEPTH_DIR = "depth"
DEPTH_INFO_FILE = "depth_info.json"


class _EpisodeDepthWriter:
    """Encodes one episode of one depth stream on a background thread."""

    def __init__(self, path: Path, width: int, height: int, fps: int):
        self.path = path
        self.width = width
        self.height = height
        self.fps = fps
        self.frames_written = 0
        self._queue: queue.Queue = queue.Queue(maxsize=256)
        self._error: BaseException | None = None
        self._thread = threading.Thread(target=self._run, name=f"depth_writer[{path.name}]", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        container = None
        stream = None
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            container = av.open(str(self.path), mode="w")
            stream = container.add_stream("ffv1", self.fps)
            stream.width = self.width
            stream.height = self.height
            stream.pix_fmt = "gray16le"

            while True:
                item = self._queue.get()
                if item is None:
                    break
                frame = av.VideoFrame.from_ndarray(item, format="gray16le")
                for packet in stream.encode(frame):
                    container.mux(packet)
                self.frames_written += 1

            for packet in stream.encode():
                container.mux(packet)
        except BaseException as e:  # noqa: BLE001 - surfaced to the caller on close()
            self._error = e
            logger.exception("Depth writer failed for %s", self.path)
        finally:
            if container is not None:
                try:
                    container.close()
                except Exception:  # noqa: BLE001
                    pass

    def add(self, depth_u16: np.ndarray) -> None:
        if self._error is not None:
            raise RuntimeError(f"Depth writer for {self.path} already failed") from self._error
        self._queue.put(depth_u16)

    def close(self) -> int:
        self._queue.put(None)
        self._thread.join()
        if self._error is not None:
            raise RuntimeError(f"Depth writer for {self.path} failed") from self._error
        return self.frames_written


class DepthRecorder:
    """Buffers raw depth per episode and commits it only when the episode is saved.

    Mirrors the dataset's episode lifecycle: `add_frame` while recording,
    `save_episode` to keep it, `discard_episode` when the operator re-records.
    """

    def __init__(self, root: Path | str, cameras: dict[str, Any], fps: int):
        self.root = Path(root)
        self.fps = int(fps)
        # Only depth cameras that can hand back raw uint16.
        self.cameras = {
            key: camera
            for key, camera in cameras.items()
            if getattr(camera, "KIND", None) == "depth" and hasattr(camera, "take_raw_depth")
        }
        self._writers: dict[str, _EpisodeDepthWriter] = {}
        self._episode_index: int | None = None
        self._frames_in_episode = 0

    @property
    def enabled(self) -> bool:
        return bool(self.cameras)

    def episode_path(self, key: str, episode_index: int) -> Path:
        return self.root / DEPTH_DIR / key / f"episode_{episode_index:06d}.mkv"

    def start_episode(self, episode_index: int) -> None:
        if not self.enabled:
            return
        self._discard_writers()
        self._episode_index = episode_index
        self._frames_in_episode = 0

    def add_frame(self) -> None:
        """Record one depth frame per stream, paired with the frame just observed.

        Must be called immediately after the observation that produced the RGB
        frame added to the dataset, so depth and RGB stay index-aligned.
        """
        if not self.enabled or self._episode_index is None:
            return

        for key, camera in self.cameras.items():
            depth = camera.take_raw_depth()
            if depth is None:
                logger.warning("No raw depth available for '%s'; skipping this frame", key)
                continue

            depth = np.ascontiguousarray(depth, dtype=np.uint16)
            writer = self._writers.get(key)
            if writer is None:
                height, width = depth.shape[:2]
                writer = _EpisodeDepthWriter(
                    self.episode_path(key, self._episode_index), width, height, self.fps
                )
                self._writers[key] = writer
            writer.add(depth)

        self._frames_in_episode += 1

    def save_episode(self) -> dict[str, int]:
        if not self.enabled or self._episode_index is None:
            return {}

        written = {}
        for key, writer in self._writers.items():
            written[key] = writer.close()
        self._writers.clear()

        for key, count in written.items():
            if count != self._frames_in_episode:
                logger.warning(
                    "Depth stream '%s' wrote %d frames but the episode has %d; "
                    "depth and RGB may be misaligned for this episode",
                    key,
                    count,
                    self._frames_in_episode,
                )

        self._episode_index = None
        self._frames_in_episode = 0
        return written

    def discard_episode(self) -> None:
        if not self.enabled:
            return
        self._discard_writers()
        self._episode_index = None
        self._frames_in_episode = 0

    def _discard_writers(self) -> None:
        for key, writer in self._writers.items():
            try:
                writer.close()
            except Exception:  # noqa: BLE001 - we are throwing the file away anyway
                logger.debug("Ignoring failure while closing discarded depth writer for %s", key)
            writer.path.unlink(missing_ok=True)
            parent = writer.path.parent
            if parent.is_dir() and not any(parent.iterdir()):
                shutil.rmtree(parent, ignore_errors=True)
        self._writers.clear()

    def write_metadata(self) -> None:
        """Record depth scale and intrinsics so frames can be unprojected later."""
        if not self.enabled:
            return

        info: dict[str, Any] = {
            "format": "ffv1/gray16le",
            "path": f"{DEPTH_DIR}/{{key}}/episode_{{episode_index:06d}}.mkv",
            "note": (
                "metres = pixel * depth_scale_m; 0 means no return. Depth is aligned "
                "to the colour camera, so depth[y,x] matches that camera's rgb[y,x] "
                "and `intrinsics` applies to both."
            ),
            "cameras": {},
        }

        for key, camera in self.cameras.items():
            # RealSense keeps calibration on the shared manager; Orbbec on the camera.
            provider = next(
                (
                    candidate
                    for candidate in (camera, getattr(camera, "manager", None))
                    if candidate is not None and hasattr(candidate, "get_calibration")
                ),
                None,
            )
            calibration: dict[str, Any] = {}
            if provider is not None:
                try:
                    calibration = provider.get_calibration()
                except Exception as e:  # noqa: BLE001 - metadata must not break recording
                    logger.warning("Could not read calibration for depth camera '%s': %s", key, e)
            else:
                logger.warning("Depth camera '%s' exposes no calibration; intrinsics will be missing", key)
            info["cameras"][key] = calibration

        path = self.root / "meta" / DEPTH_INFO_FILE
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as stream:
            json.dump(info, stream, indent=4)

    def close(self) -> None:
        self.discard_episode()
