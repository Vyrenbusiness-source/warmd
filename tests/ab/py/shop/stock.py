"""Warehouse stock with reservations."""


class Stock:
    def __init__(self, levels):
        self.levels = dict(levels)

    def available(self, sku):
        return self.levels.get(sku, 0)

    def reserve(self, sku, qty):
        if qty > self.available(sku):
            return False
        self.levels[sku] -= qty
        return True
