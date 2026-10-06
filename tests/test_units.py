from reporter.inference import ColumnProfile, converter
from reporter.naming import sanitize_headers, validate_client
import pytest


def prof(values, **kw):
    p = ColumnProfile(**kw)
    for v in values:
        p.add(v)
    return p.mysql_type()


def test_types():
    assert prof(["1", "22", ""]) == "BIGINT"
    assert prof(["1.50", "2"]).startswith("DECIMAL")
    assert prof(["2024-01-02"]) == "DATE"
    assert prof(["2024-01-02 10:00:00"]) == "DATETIME"
    assert prof(["abc"]) == "VARCHAR(255)"
    assert prof(["x" * 300]) == "TEXT"
    assert prof(["01/02/2024"], date_fmt="%d/%m/%Y") == "DATE"


def test_converter():
    assert converter("bigint")("5") == 5
    with pytest.raises(ValueError):
        converter("date")("nope")


def test_names():
    assert sanitize_headers(["Customer ID", "customer id", "", "1st"]) == [
        "customer_id", "customer_id_2", "col_3", "c_1st"]
    assert validate_client("Acme_1") == "acme_1"
    with pytest.raises(ValueError):
        validate_client("bad name; drop")
