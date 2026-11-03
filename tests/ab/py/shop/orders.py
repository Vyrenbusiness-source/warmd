"""Turns parsed lines into an order against stock and a price list."""
from shop.parse import parse_lines
from shop.stock import Stock


def place(text, stock: Stock, prices):
    order, missing = [], []
    for sku, qty in parse_lines(text):
        (order if stock.reserve(sku, qty) else missing).append((sku, qty))
    total = sum(prices[sku] * qty for sku, qty in order)
    return {"lines": order, "missing": missing, "total": total}
