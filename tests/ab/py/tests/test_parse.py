import pytest
from shop.parse import parse_line, parse_lines


def test_line():
    assert parse_line(" A1 , 3 ") == ("A1", 3)


def test_skips_comments_and_blanks():
    assert parse_lines("A1,1\n\n# note\nB2,2") == [("A1", 1), ("B2", 2)]


def test_empty_sku():
    with pytest.raises(ValueError):
        parse_line(",2")
