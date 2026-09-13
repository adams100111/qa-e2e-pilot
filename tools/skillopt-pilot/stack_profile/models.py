"""Strict Pydantic schemas for committed benchmark data."""

from __future__ import annotations

from typing import Any, Self

from pydantic import BaseModel, ConfigDict, Field, model_validator


class AssertionModel(BaseModel):
    model_config = ConfigDict(extra="forbid")

    path: str = Field(min_length=1)
    equals: Any = None
    not_equals: Any = None

    @model_validator(mode="after")
    def require_one_operator(self) -> Self:
        operators = self.model_fields_set & {"equals", "not_equals"}
        if len(operators) != 1:
            raise ValueError("assertion must contain exactly one of equals or not_equals")
        return self


class BenchmarkItemModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    id: str = Field(min_length=1)
    fixture: str = Field(min_length=1)
    prompt: str = Field(min_length=1)
    assertions: list[AssertionModel] = Field(min_length=1)
    task_type: str = Field(default="stack-profile", min_length=1)

