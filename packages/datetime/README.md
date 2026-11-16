# datetime

Dates, times and instants on the proleptic Gregorian calendar, with UTC and fixed UTC offsets. Parses and formats RFC 3339 / ISO 8601, and formats with strftime-style patterns and HTTP dates. A `DateTime` is an instant (Unix milliseconds) plus the offset used to display it, so comparing and subtracting instants never depends on the offset. Errors are a typed `DateErr`.

**Effects:** none. The package never reads the clock; pass it in with `datetime.from_unix_ms(time.now())` (which needs `uses time` in *your* code).

```duck
fn main(): int! uses time {
  let now = datetime.from_unix_ms(time.now())
  let due = datetime.parse("2024-02-29T13:05:09.120+05:30")?
  print("{due}")                                    // 2024-02-29T13:05:09.120+05:30
  print("{due.date()} {due.weekday()}")             // 2024-02-29 Thu
  print(due.add(1, datetime.Month))                 // 2024-03-29T13:05:09.120+05:30 (clamped at month end)
  print(datetime.format(due.utc(), "%a %d %b %Y %H:%M"))  // Thu 29 Feb 2024 07:35
  print(datetime.http_date(now))                    // e.g. Fri, 30 Oct 2026 09:12:44 GMT
  let late_ms = datetime.diff(now, due)             // milliseconds
  let d = datetime.date(2024, 2, 30) else e => fail(datetime.message(e))  // day out of range: 30
  0
}
```

## API
Types:
- `struct Date { year, month, day }` and `struct Time { hour, minute, second, ms }` (all `int`). The fields are public; build them with `date`/`time` to validate.
- `struct DateTime { ms: int, offset_min: int }`: milliseconds since 1970-01-01T00:00:00Z, and the display offset in minutes east of UTC (-1439..1439).
- `enum Weekday { Mon, Tue, Wed, Thu, Fri, Sat, Sun }`, `enum Unit { Ms, Sec, Min, Hour, Day, Week, Month, Year }`
- `enum DateErr { Syntax(expected: str, col: int), OutOfRange(field: str, value: int) }`, and `message(e): str` (`col 6: expected 2-digit month`, `day out of range: 30`)

Calendar (on `Date`):
- `date(y, m, d): Date!DateErr`, `time(h, m, s, ms): Time!DateErr`: validated constructors (|year| <= 999,999)
- `is_leap(year): bool`, `days_in_month(year, month): int`, `day_of_year(d): int`
- `days(d): int` (days since 1970-01-01) and `from_days(n): Date`
- `weekday(d): Weekday` (also on `DateTime`), `number(w): int` (ISO: Mon = 1 .. Sun = 7)
- `add_days(d, n): Date`, `add_months(d, n): Date` (clamps the day), `diff(a, b): int` (days)

Instants (on `DateTime`):
- `from_unix_ms(ms): DateTime` (UTC), `unix_ms(d): int`
- `utc(y, m, d, h, mi, s): DateTime!DateErr`, `make(date, time, offset_min): DateTime!DateErr`
- `utc(d): DateTime`, `with_offset(d, minutes): DateTime!DateErr`: the same instant shown elsewhere
- `date(d): Date`, `time(d): Time`: the local fields at `d`'s offset
- `add(d, n, unit): DateTime`: `Ms`..`Week` are exact; `Month`/`Year` move the local date, clamped
- `diff(a, b): int` (milliseconds, `a - b`)
- `<`, `sort`: `DateTime` orders by instant (then offset); `Date` and `Time` order chronologically

Text:
- `parse(s): DateTime!DateErr`: `YYYY-MM-DD` + `T`/`t`/space + `hh:mm[:ss[.fff…]]` + `Z`/`z`/`±hh:mm`/`±hhmm`/`±hh`. A date alone is midnight UTC; otherwise the offset is required. Extra fraction digits are truncated to ms.
- `parse_date(s): Date!DateErr`, `parse_time(s): Time!DateErr`
- `show`, i.e. `"{x}"`: RFC 3339 `2024-02-29T13:05:09.120Z` (ms omitted when zero, `Z` for offset 0); `Date` as `2024-02-29`, `Time` as `13:05:09` or `13:05:09.120`
- `format(d, pattern): str`: `%Y %m %d %H %M %S`, `%L` (ms), `%j` (day of year), `%a %A` (`Mon`, `Monday`), `%b %B` (`Jan`, `January`), `%u` (ISO weekday), `%s` (Unix seconds), `%z` (`+0530`), `%Z` (`Z` or `+05:30`), `%%`
- `http_date(d): str`: `Sun, 06 Nov 1994 08:49:37 GMT` (always GMT)

## Design notes and limits (0.1)
- **Time zones:** UTC and fixed offsets only. There is no IANA time zone database (`Europe/Paris`, daylight saving), so `Day` always means 24 hours. Store the zone name yourself and pass the offset in for now.
- **Calendar:** the proleptic Gregorian calendar for every year, with astronomical year numbering (year 0 = 1 BC, and negative years are allowed). Years outside 0000..9999 are written with a sign (`-0044-03-15`, `+12345-01-01`), but `parse` reads 4-digit years only, as RFC 3339 does.
- **Precision:** milliseconds, to match `time.now()`. Leap seconds are not represented: `23:59:60` is an `OutOfRange` error, as in Unix time.
- **Plain `int` milliseconds, not `int<ms>`:** core `time.now()` returns a plain `int`, and a plain `int` doesn't convert to `int<ms>` implicitly, so a unit would make `from_unix_ms(time.now())` and every caller's arithmetic need conversions. Durations are just `diff` results in ms, and `add` takes a `Unit`, so units of measure would add noise without catching real bugs here.
