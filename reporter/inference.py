from datetime import date, datetime
from decimal import Decimal, InvalidOperation

DATE_FORMATS = ["%Y-%m-%d", "%Y/%m/%d"]
DATETIME_FORMATS = ["%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y/%m/%d %H:%M:%S"]


def _parse(value, formats):
    for f in formats:
        try:
            return datetime.strptime(value, f)
        except ValueError:
            pass
    raise ValueError(value)


def to_date(v, fmt=None):
    return _parse(v, [fmt] if fmt else DATE_FORMATS).date()


def to_datetime(v, fmt=None):
    return _parse(v, [fmt] if fmt else DATETIME_FORMATS)


def to_int(v):
    if not v.lstrip("+-").isdigit():
        raise ValueError(v)
    return int(v)


def to_decimal(v):
    try:
        d = Decimal(v)
    except InvalidOperation:
        raise ValueError(v)
    if not d.is_finite():
        raise ValueError(v)
    return d


class ColumnProfile:
    """Accumulates values for one column and suggests a MySQL type."""

    def __init__(self, date_fmt=None, datetime_fmt=None):
        self.date_fmt, self.datetime_fmt = date_fmt, datetime_fmt
        self.is_int = self.is_dec = self.is_date = self.is_dt = True
        self.max_len = 1
        self.max_scale = 0
        self.max_digits = 1
        self.seen = False

    def add(self, v):
        if v is None or v == "":
            return
        self.seen = True
        self.max_len = max(self.max_len, len(v))
        if self.is_int:
            try:
                to_int(v)
            except ValueError:
                self.is_int = False
        if self.is_dec:
            try:
                d = to_decimal(v)
                exp = -d.as_tuple().exponent
                self.max_scale = max(self.max_scale, max(exp, 0))
                self.max_digits = max(self.max_digits, len(d.as_tuple().digits))
            except ValueError:
                self.is_dec = False
        if self.is_date:
            try:
                to_date(v, self.date_fmt)
            except ValueError:
                self.is_date = False
        if self.is_dt:
            try:
                to_datetime(v, self.datetime_fmt)
            except ValueError:
                self.is_dt = False

    def mysql_type(self) -> str:
        if not self.seen:
            return "VARCHAR(255)"
        if self.is_int and self.max_len <= 18:
            return "BIGINT"
        if self.is_dec:
            scale = min(self.max_scale, 10)
            int_digits = max(self.max_digits - self.max_scale, 1)
            precision = min(max(int_digits + scale, 1) + 8, 38)
            return f"DECIMAL({precision},{min(scale, precision)})"
        if self.is_date:
            return "DATE"
        if self.is_dt:
            return "DATETIME"
        if self.max_len <= 255:
            return "VARCHAR(255)"
        return "TEXT"


def converter(mysql_data_type: str, date_fmt=None, datetime_fmt=None):
    """Return a function converting a staged string into a Python value."""
    t = mysql_data_type.lower()
    if t in ("tinyint", "smallint", "mediumint", "int", "bigint"):
        return to_int
    if t in ("decimal", "numeric", "float", "double"):
        return to_decimal
    if t == "date":
        return lambda v: to_date(v, date_fmt)
    if t in ("datetime", "timestamp"):
        return lambda v: to_datetime(v, datetime_fmt)
    return lambda v: v
