"""Money as integer cents."""


def split(total, parts):
    """Split total cents into `parts` shares that add up to total, larger shares first."""
    if parts <= 0:
        raise ValueError("parts must be positive")
    base = total // parts
    return [base] * parts


def fmt(cents):
    return f"{cents // 100}.{cents % 100:02d}"
