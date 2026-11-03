"""Reads order lines like 'sku,qty'."""


def parse_line(line):
    sku, qty = (p.strip() for p in line.split(","))
    if not sku:
        raise ValueError("empty sku")
    return sku, int(qty)


def parse_lines(text):
    return [parse_line(l) for l in text.splitlines() if l.strip() and not l.lstrip().startswith("#")]
