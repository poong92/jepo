#!/usr/bin/env python3
"""
JEPO Autopilot v0.2.0 — Output Validator
Validates Claude structured outputs (JSON schema + text safety).

Usage:
    echo '{"verdict":"APPROVE","score":95,"summary":"LGTM"}' | python3 output-validator.py json pr-review
    echo "Hello tweet" | python3 output-validator.py text tweet 280
"""
import sys
import json
import re
from typing import Any, Dict, List, Tuple

# Schema definitions
SCHEMAS = {
    "pr-review": {
        "required": ["verdict", "score", "summary"],
        "fields": {
            "verdict": {"type": "enum", "values": ["APPROVE", "REQUEST_CHANGES"]},
            "score": {"type": "range", "min": 0, "max": 100},
            "summary": {"type": "string", "max_length": 500},
            "issues": {"type": "array", "required": False},
        },
    },
    "improvement": {
        "required": ["priority", "title", "file"],
        "fields": {
            "priority": {"type": "enum", "values": ["P0", "P1", "P2", "P3"]},
            "title": {"type": "string", "max_length": 200},
            "file": {"type": "string", "max_length": 500},
        },
    },
    "audit": {
        "required": ["grade", "findings"],
        "fields": {
            "grade": {"type": "enum", "values": ["A", "B", "C", "D", "F"]},
            "findings": {"type": "array"},
        },
    },
    "deploy-verify": {
        "required": ["verdict", "e2e_score", "tests"],
        "fields": {
            "verdict": {"type": "enum", "values": ["PASS", "WARN", "FAIL"]},
            "e2e_score": {"type": "range", "min": 0, "max": 100},
            "tests": {"type": "array"},
        },
    },
    "agent-health": {
        "required": ["agents", "timestamp"],
        "fields": {
            "agents": {"type": "array"},
            "timestamp": {"type": "string"},
        },
    },
}

TEXT_LIMITS = {
    "tweet": 280,
    "issue_title": 100,
    "issue_body": 65536,
    "review_comment": 2000,
    "improvement": 5000,
    "audit_report": 50000,
    "alert_message": 4096,
}


def extract_json(content: str) -> str:
    """Extract JSON from potential markdown fences."""
    match = re.search(r"```(?:json)?\s*\n(.*?)\n\s*```", content, re.DOTALL)
    if match:
        return match.group(1).strip()
    content = content.strip()
    # Try to find JSON object/array boundaries
    for start_char, end_char in [("{", "}"), ("[", "]")]:
        start = content.find(start_char)
        end = content.rfind(end_char)
        if start != -1 and end != -1 and end > start:
            return content[start : end + 1]
    return content


def validate_field(field_name: str, value: Any, rules: Dict) -> Tuple[bool, str]:
    """Validate a single field against its rules."""
    field_type = rules.get("type", "string")

    if field_type == "enum":
        if value not in rules["values"]:
            return False, f"Invalid {field_name}: '{value}' not in {rules['values']}"

    elif field_type == "range":
        if not isinstance(value, (int, float)):
            return False, f"Invalid {field_name}: expected number, got {type(value).__name__}"
        if value < rules["min"] or value > rules["max"]:
            return False, f"Invalid {field_name}: {value} not in [{rules['min']}, {rules['max']}]"

    elif field_type == "string":
        if not isinstance(value, str):
            return False, f"Invalid {field_name}: expected string, got {type(value).__name__}"
        max_len = rules.get("max_length", 65536)
        if len(value) > max_len:
            return False, f"Invalid {field_name}: length {len(value)} > {max_len}"

    elif field_type == "array":
        if not isinstance(value, list):
            return False, f"Invalid {field_name}: expected array, got {type(value).__name__}"

    return True, ""


def validate_json_output(content: str, schema_name: str) -> Dict:
    """Validate structured JSON output against a named schema."""
    schema = SCHEMAS.get(schema_name)
    if not schema:
        return {"valid": False, "error": f"Unknown schema: {schema_name}"}

    json_str = extract_json(content)

    try:
        data = json.loads(json_str)
    except json.JSONDecodeError as e:
        return {"valid": False, "error": f"Invalid JSON: {e}"}

    if not isinstance(data, dict):
        return {"valid": False, "error": f"Expected object, got {type(data).__name__}"}

    # Check required fields
    for field in schema["required"]:
        if field not in data:
            return {"valid": False, "error": f"Missing required field: {field}"}

    # Validate field values
    errors = []
    for field_name, rules in schema.get("fields", {}).items():
        if field_name not in data:
            if rules.get("required", True) and field_name in schema["required"]:
                errors.append(f"Missing: {field_name}")
            continue
        ok, err = validate_field(field_name, data[field_name], rules)
        if not ok:
            errors.append(err)

    if errors:
        return {"valid": False, "error": "; ".join(errors)}

    return {"valid": True, "content": data, "metadata": {"schema": schema_name, "fields": list(data.keys())}}


def validate_text_output(content: str, output_type: str, max_tokens: int = 1000) -> Dict:
    """Validate free-form text output."""
    max_len = TEXT_LIMITS.get(output_type, max_tokens)

    if len(content) > max_len:
        return {"valid": False, "error": f"Too long: {len(content)} > {max_len}"}

    # Check for non-printable characters (except newline/tab)
    unsafe_chars = []
    for i, ch in enumerate(content):
        if not (ch.isprintable() or ch in "\n\t\r"):
            unsafe_chars.append({"pos": i, "ord": ord(ch)})

    if unsafe_chars:
        return {
            "valid": False,
            "error": f"Found {len(unsafe_chars)} unsafe character(s)",
            "metadata": {"unsafe_chars": unsafe_chars[:10]},
        }

    # Dangerous patterns for certain output types
    if output_type == "issue_title":
        dangerous = re.findall(r"[`|&;><$]", content)
        if dangerous:
            return {"valid": False, "error": f"Shell metacharacters found: {dangerous}"}
    elif output_type == "tweet":
        # $, & are normal in financial tweets (e.g., "$BTC", "supply & demand")
        dangerous = re.findall(r"[`|;><]", content)
        if dangerous:
            return {"valid": False, "error": f"Shell metacharacters found: {dangerous}"}

    return {
        "valid": True,
        "content": content,
        "metadata": {
            "length": len(content),
            "tokens_est": len(content) // 4,
            "type": output_type,
        },
    }


def main():
    if len(sys.argv) < 3:
        print("Usage: output-validator.py <text|json> <schema> [max_tokens]", file=sys.stderr)
        sys.exit(2)

    output_type = sys.argv[1]  # "text" or "json"
    schema = sys.argv[2]
    max_tokens = int(sys.argv[3]) if len(sys.argv) > 3 else 1000

    content = sys.stdin.read()

    if output_type == "json":
        result = validate_json_output(content, schema)
    elif output_type == "text":
        result = validate_text_output(content, schema, max_tokens)
    else:
        result = {"valid": False, "error": f"Unknown type: {output_type}"}

    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0 if result["valid"] else 1)


if __name__ == "__main__":
    main()
