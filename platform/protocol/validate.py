"""Validate protocol examples against the schemas.

examples/<schema>.<name>.json must be valid, examples/invalid/<schema>.<name>.json must be rejected.
"""

import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

ROOT = Path(__file__).parent


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def build_registry() -> Registry:
    resources = []
    for path in ROOT.glob("*.schema.json"):
        schema = load(path)
        Draft202012Validator.check_schema(schema)
        resources.append((path.name, Resource.from_contents(schema)))
    return Registry().with_resources(resources)


def validator_for(example: Path, registry: Registry) -> Draft202012Validator:
    schema_name = example.name.split(".", 1)[0] + ".schema.json"
    schema = load(ROOT / schema_name)
    return Draft202012Validator(schema, registry=registry, format_checker=FormatChecker())


def main() -> int:
    registry = build_registry()
    failures = 0

    for example in sorted((ROOT / "examples").glob("*.json")):
        errors = list(validator_for(example, registry).iter_errors(load(example)))
        if errors:
            failures += 1
            print(f"FAIL  {example.name}")
            for error in errors:
                print(f"      {error.json_path}: {error.message}")
        else:
            print(f"ok    {example.name}")

    for example in sorted((ROOT / "examples" / "invalid").glob("*.json")):
        if validator_for(example, registry).is_valid(load(example)):
            failures += 1
            print(f"FAIL  invalid/{example.name} was accepted")
        else:
            print(f"ok    invalid/{example.name} rejected")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
