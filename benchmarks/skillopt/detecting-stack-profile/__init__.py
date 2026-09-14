"""detecting-stack-profile SkillOpt benchmark package.

Source of truth lives in the qa-e2e-pilot repo under
``benchmarks/skillopt/detecting-stack-profile/``. It is copied into a SkillOpt
checkout as ``skillopt/envs/detecting_stack_profile/`` by ``install-into-skillopt.sh``
(hyphens -> underscores, since a Python package name cannot contain hyphens).
"""
from .env import DetectingStackProfileEnv

__all__ = ["DetectingStackProfileEnv"]
