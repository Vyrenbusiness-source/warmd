from shop.report import receipt


def test_receipt_single():
    assert receipt({"lines": [("A1", 2)], "total": 500}) == "A1 x2\ntotal 5.00"


def test_receipt_shared():
    assert receipt({"lines": [("A1", 1)], "total": 500}, payers=2).endswith("each 2.50 / 2.50")
