import re

TIERS = ("stg", "ods", "dw")
ADMIN_SCHEMA = "reporter_admin"
_CLIENT_RE = re.compile(r"^[a-z][a-z0-9_]{0,29}$")


def validate_client(name: str) -> str:
    name = name.strip().lower()
    if not _CLIENT_RE.match(name):
        raise ValueError(
            "Client name must start with a letter and contain only a-z, 0-9, _ (max 30 chars)"
        )
    return name


def schema(client: str, tier: str) -> str:
    return f"{validate_client(client)}_{tier}"


def q(identifier: str) -> str:
    """Quote an identifier for MySQL."""
    return "`" + identifier.replace("`", "``") + "`"


def sanitize(name: str, fallback: str = "col") -> str:
    s = re.sub(r"[^a-z0-9]+", "_", name.strip().lower()).strip("_")
    if not s:
        s = fallback
    if s[0].isdigit():
        s = "c_" + s
    return s[:60]


def sanitize_headers(headers: list[str]) -> list[str]:
    out, seen = [], set()
    for i, h in enumerate(headers, 1):
        base = sanitize(h, f"col_{i}")
        name, n = base, 2
        while name in seen:
            name = f"{base}_{n}"
            n += 1
        seen.add(name)
        out.append(name)
    return out
