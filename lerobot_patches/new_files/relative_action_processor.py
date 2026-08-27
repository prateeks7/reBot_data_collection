#!/usr/bin/env python

# Copyright 2025 The HuggingFace Inc. team. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Stand-in for a policy-relative-action feature this fork never implemented.

Checkpoints trained with a newer lerobot serialise a `relative_actions_processor`
/ `absolute_actions_processor` pair into their pipeline JSON whenever the
policy config has `use_relative_actions` (see `PI05Config`). This fork's
`ProcessorStepRegistry` has never had matching step classes, so loading such a
checkpoint fails at `PolicyProcessorPipeline.from_pretrained` before a single
observation is processed -- regardless of whether the feature is actually on.

Both steps below are identity transforms when `enabled=False`, which is the
only state this fork can honestly claim to support: a checkpoint trained with
`use_relative_actions=False` behaves exactly as it did before these steps
existed. `enabled=True` raises immediately at construction time (unpickling
the checkpoint's own JSON), rather than silently running an absolute-action
checkpoint's plumbing over a relative-action policy's outputs and sending
whatever that produces to the robot.
"""

from dataclasses import dataclass, field

from lerobot.configs.types import PipelineFeatureType, PolicyFeature

from .core import PolicyAction, RobotObservation
from .pipeline import ObservationProcessorStep, PolicyActionProcessorStep, ProcessorStepRegistry


@ProcessorStepRegistry.register("relative_actions_processor")
@dataclass
class RelativeActionsProcessorStep(ObservationProcessorStep):
    """Preprocessor half of the relative-action pair. See module docstring."""

    enabled: bool = False
    exclude_joints: list[str] = field(default_factory=list)
    action_names: list[str] | None = None

    def __post_init__(self) -> None:
        if self.enabled:
            raise NotImplementedError(
                "This checkpoint was saved with relative_actions_processor enabled=True, but "
                "this fork never implemented that transform (only the disabled/absolute-action "
                "path has been exercised). Loading it anyway would run the observation through "
                "an unimplemented no-op instead of the real relative-state encoding the policy "
                "was trained on."
            )

    def observation(self, observation: RobotObservation) -> RobotObservation:
        return observation

    def transform_features(
        self, features: dict[PipelineFeatureType, dict[str, PolicyFeature]]
    ) -> dict[PipelineFeatureType, dict[str, PolicyFeature]]:
        return features


@ProcessorStepRegistry.register("absolute_actions_processor")
@dataclass
class AbsoluteActionsProcessorStep(PolicyActionProcessorStep):
    """Postprocessor half of the relative-action pair. See module docstring."""

    enabled: bool = False

    def __post_init__(self) -> None:
        if self.enabled:
            raise NotImplementedError(
                "This checkpoint was saved with absolute_actions_processor enabled=True, but "
                "this fork never implemented the matching relative-action policy output -- it "
                "would send whatever the unconverted tensor happens to contain straight to the "
                "robot instead of the intended absolute joint targets."
            )

    def action(self, action: PolicyAction) -> PolicyAction:
        return action

    def transform_features(
        self, features: dict[PipelineFeatureType, dict[str, PolicyFeature]]
    ) -> dict[PipelineFeatureType, dict[str, PolicyFeature]]:
        return features
