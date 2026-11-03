from shop.orders import place
from shop.stock import Stock


def test_place_and_missing():
    o = place("A1,2\nB2,9", Stock({"A1": 3, "B2": 1}), {"A1": 250, "B2": 100})
    assert o["lines"] == [("A1", 2)] and o["missing"] == [("B2", 9)] and o["total"] == 500
