from shop.stock import Stock


def test_reserve_ok():
    s = Stock({"A1": 5})
    assert s.reserve("A1", 5) and s.available("A1") == 0


def test_reserve_too_much():
    s = Stock({"A1": 2})
    assert not s.reserve("A1", 3) and s.available("A1") == 2


def test_unknown_sku():
    assert Stock({}).available("Z9") == 0
