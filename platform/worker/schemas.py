"""Protocol schema validation."""

import json
import os
from functools import cache
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

PROTOCOL_DIR = Path(os.environ.get("PROTOCOL_DIR", "/opt/worker/protocol"))


@cache
def _validator(name: str) -> Draft202012Validator:
    resources = [
        (path.name, Resource.from_contents(json.loads(path.read_text(encoding="utf-8"))))
        for path in PROTOCOL_DIR.glob("*.schema.json")
    ]
    registry = Registry().with_resources(resources)
    schema = json.loads((PROTOCOL_DIR / f"{name}.schema.json").read_text(encoding="utf-8"))
    return Draft202012Validator(schema, registry=registry)


def errors(name: str, instance) -> list[str]:
    return [f"{e.json_path}: {e.message}" for e in _validator(name).iter_errors(instance)]
