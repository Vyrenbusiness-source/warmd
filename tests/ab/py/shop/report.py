"""Plain text receipt."""
from shop import money


def receipt(order, payers=1):
    rows = [f"{sku} x{qty}" for sku, qty in order["lines"]]
    rows.append(f"total {money.fmt(order['total'])}")
    if payers > 1:
        rows.append("each " + " / ".join(money.fmt(s) for s in money.split(order["total"], payers)))
    return "\n".join(rows)
