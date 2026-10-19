#!/usr/bin/env python3
"""Reject private Azure identifiers and credential material in public files.

Only filenames and rule names are reported. Matched values are never printed,
so CI logs cannot become a second disclosure surface. The checker uses only
the Python standard library and scans tracked plus non-ignored candidate files.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# Microsoft-published policy and role-definition identifiers used by this
# repository. Adding a GUID is an explicit review decision; never add a live
# tenant, principal, assignment, resource, operation, or job identifier.
PUBLIC_GUIDS = {
    # Microsoft Azure Update Manager built-in policies.
    "59efceea-0c96-497e-a4a1-4eb2290dac15",  # periodic assessment, Azure VMs
    "bfea026e-043f-4ff4-9d1b-bf301ca7ff46",  # periodic assessment, Arc-enabled servers
    "9905ca54-1471-49c6-8291-7582c04cd4d4",  # scheduling prerequisite (Customer Managed Schedules)
    "ba0df93e-e4ac-479a-aac2-134bbae39a1a",  # schedule recurring updates
    "bd876905-5b84-4f73-ab2d-2e7a7c4568d9",  # audit: periodic check configured
    "f85bf3e0-d513-442e-89c3-1784ad63382b",  # audit: system updates installed
    # Microsoft built-in roles referenced by scripts and templates.
    "b24988ac-6180-42a0-ab88-20f7382dd24c",  # Contributor
    "acdd72a7-3385-48ef-bd42-f606fba81ae7",  # Reader
    "7efff54f-a5b4-42b5-a1c5-5411624893ce",  # Disk Snapshot Contributor
    "9980e02c-c2be-4d73-94e8-173b1dc7cf3c",  # Virtual Machine Contributor
    "cd08ab90-6b14-449c-ad9a-8f8e549482c6",  # Scheduled Patching Contributor
    "73c42c96-874c-492b-b04d-ab87d138a893",  # Log Analytics Reader
    # Clearly synthetic fixtures/placeholders.
    "00000000-0000-0000-0000-000000000000",
    "11111111-1111-1111-1111-111111111111",
}
SYNTHETIC_SCOPE_GUIDS = {
    "00000000-0000-0000-0000-000000000000",
    "11111111-1111-1111-1111-111111111111",
}

GUID_RE = re.compile(
    r"(?i)(?<![0-9a-f])"
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    r"(?![0-9a-f])"
)
ARM_TENANT_SCOPE_RE = re.compile(
    r"(?i)/(?:subscriptions|tenants)/"
    r"(?P<guid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
    r"[0-9a-f]{4}-[0-9a-f]{12})(?:/|\b)"
)
EMAIL_RE = re.compile(
    r"(?i)(?<![A-Z0-9._%+-])"
    r"[A-Z0-9._%+-]+@(?P<domain>[A-Z0-9.-]+\.[A-Z]{2,})"
)
ALLOWED_EMAIL_DOMAINS = {
    "example.com",
    "example.net",
    "example.org",
    "users.noreply.github.com",
}

POSIX_HOME_RE = re.compile(
    r"(?<![A-Za-z0-9])(?:/home/|/Users/)"
    r"(?!(?:runner|site|vsts)(?:/|\b))[A-Za-z0-9._-]+"
)
WINDOWS_HOME_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9])[A-Z]:[\\/]Users[\\/]"
    r"(?!(?:runner|vsts)(?:[\\/]|\b))[^\\/\s]+"
)
# Split this literal so the checker does not identify its own rule definition.
ROOT_HOME_RE = re.compile(r"(?<![A-Za-z0-9])/" + r"root(?:/|\b)")

PRIVATE_KEY_RE = re.compile(r"(?i)-----BEGIN [A-Z0-9 -]*PRIVATE KEY-----")
GITHUB_TOKEN_RE = re.compile(
    r"(?i)(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"
)
JWT_RE = re.compile(
    r"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\."
    r"[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
)
STORAGE_SECRET_RE = re.compile(
    r"(?i)\b(?:AccountKey|SharedAccessSignature)\s*=\s*"
    r"(?P<value>[^;\s\"']+)"
)
SAS_SIGNATURE_RE = re.compile(
    r"(?i)(?:[?&]|\b)sig\s*=\s*(?P<value>[A-Za-z0-9%_+\-/]{8,})"
)
SECRET_ASSIGNMENT_RE = re.compile(
    r"(?ix)"
    r"[\"']?(?:client[_-]?secret|azure[_-]?client[_-]?secret|"
    r"arm[_-]?client[_-]?secret|password|passwd|api[_-]?key|"
    r"access[_-]?token|refresh[_-]?token)[\"']?"
    r"\s*[:=]\s*[\"']?(?P<value>[^\s\"'`,;#]{8,})"
)
WEBHOOK_TOKEN_RE = re.compile(
    r"(?i)azure-automation\.net/webhooks\?token=(?P<value>[^\s\"'&]{8,})"
)
CLI_SECRET_RE = re.compile(
    r"(?i)--(?:client-secret|password)\s+"
    r"[\"']?(?P<value>[^\s\"']{8,})"
)

SHELL_PLACEHOLDER_RE = re.compile(
    r"^\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})$"
)
ANGLE_PLACEHOLDER_RE = re.compile(r"^<[^<>\r\n]+>$")
TEMPLATE_PLACEHOLDER_RE = re.compile(r"^\{\{[^{}\r\n]+\}\}$")
SENTINEL_PLACEHOLDER_RE = re.compile(
    r"(?i)^(?:"
    r"(?:example|redacted|dummy|changeme|replace(?:[-_]?me)?)"
    r"(?:[-_][a-z0-9]+)*"
    r"|your(?:[-_][a-z0-9]+)+"
    r"|\*{3,}"
    r")$"
)


def repository_files() -> list[Path]:
    """Return tracked and non-ignored candidate files without reading .git."""

    result = subprocess.run(
        [
            "git",
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    names = result.stdout.decode("utf-8", errors="strict").split("\0")
    return sorted(ROOT / name for name in names if name)


def path_rules(relative: Path) -> set[str]:
    rules: set[str] = set()
    parts = tuple(part.lower() for part in relative.parts)
    name = relative.name.lower()
    posix = relative.as_posix().lower()

    if (name.startswith(".env") or name.endswith(".env")) and not name.endswith(".env.example"):
        rules.add("private-environment-file")
    if any(part in {".private", ".generated", ".azure"} for part in parts):
        rules.add("private-artifact-path")
    if "/evidence/raw/" in f"/{posix}/" or "raw-evidence" in parts:
        rules.add("raw-evidence-path")
    if name.endswith((".har", ".cast")):
        rules.add("raw-session-capture")
    if name.endswith(".tfstate") or ".tfstate." in name:
        rules.add("terraform-state")
    if name.endswith((".pfx", ".p12", ".key")):
        rules.add("private-key-artifact")
    if name.endswith((".orig", ".bak", ".swp", ".swo", ".rej")) or name.endswith("~"):
        rules.add("editor-backup-artifact")
    return rules


def is_placeholder(value: str) -> bool:
    return any(
        regex.fullmatch(value)
        for regex in (
            SHELL_PLACEHOLDER_RE,
            ANGLE_PLACEHOLDER_RE,
            TEMPLATE_PLACEHOLDER_RE,
            SENTINEL_PLACEHOLDER_RE,
        )
    )


def credential_rules(text: str) -> set[str]:
    rules: set[str] = set()
    if PRIVATE_KEY_RE.search(text):
        rules.add("private-key-material")
    if GITHUB_TOKEN_RE.search(text) or JWT_RE.search(text):
        rules.add("token-material")

    for regex in (
        STORAGE_SECRET_RE,
        SAS_SIGNATURE_RE,
        WEBHOOK_TOKEN_RE,
        SECRET_ASSIGNMENT_RE,
        CLI_SECRET_RE,
    ):
        for match in regex.finditer(text):
            if not is_placeholder(match.group("value")):
                rules.add("credential-material")
                break
    return rules


def content_rules(text: str) -> set[str]:
    rules: set[str] = set()

    for match in ARM_TENANT_SCOPE_RE.finditer(text):
        if match.group("guid").lower() not in SYNTHETIC_SCOPE_GUIDS:
            rules.add("tenant-arm-guid-path")

    if any(
        match.group(0).lower() not in PUBLIC_GUIDS
        for match in GUID_RE.finditer(text)
    ):
        rules.add("unapproved-guid")

    for match in EMAIL_RE.finditer(text):
        if match.group("domain").lower() not in ALLOWED_EMAIL_DOMAINS:
            rules.add("non-example-email")
            break

    if (
        POSIX_HOME_RE.search(text)
        or WINDOWS_HOME_RE.search(text)
        or ROOT_HOME_RE.search(text)
    ):
        rules.add("personal-home-path")

    rules.update(credential_rules(text))
    return rules


def main() -> int:
    findings: set[tuple[str, str]] = set()
    try:
        paths = repository_files()
    except (OSError, subprocess.CalledProcessError, UnicodeDecodeError):
        print(".: repository-enumeration-error", file=sys.stderr)
        return 1

    for path in paths:
        relative = path.relative_to(ROOT)
        for rule in path_rules(relative):
            findings.add((relative.as_posix(), rule))

        if path.is_symlink():
            findings.add((relative.as_posix(), "symlinked-public-file"))
            continue
        try:
            data = path.read_bytes()
            if b"\0" in data:
                findings.add((relative.as_posix(), "binary-public-file"))
                continue
            text = data.decode("utf-8")
        except (OSError, UnicodeDecodeError):
            findings.add((relative.as_posix(), "unreadable-or-non-utf8-file"))
            continue

        for rule in content_rules(text):
            findings.add((relative.as_posix(), rule))

    if findings:
        print("Public-content privacy check failed:", file=sys.stderr)
        for filename, rule in sorted(findings):
            print(f"  {filename}: {rule}", file=sys.stderr)
        return 1

    print("Public-content privacy check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
