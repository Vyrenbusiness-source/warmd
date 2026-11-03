import pytest
from shop.money import split, fmt


def test_split_even():
    assert split(900, 3) == [300, 300, 300]


def test_split_keeps_every_cent():
    assert split(1000, 3) == [334, 333, 333]


def test_split_rejects_zero():
    with pytest.raises(ValueError):
        split(100, 0)


def test_fmt():
    assert fmt(1205) == "12.05"
