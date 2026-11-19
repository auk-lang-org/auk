/// Dates, times and instants: proleptic Gregorian calendar math, UTC and fixed UTC offsets,
/// RFC 3339 / ISO 8601 parsing and formatting. Pure: no effects. Pass the clock in yourself:
/// `datetime.from_unix_ms(time.now())`.

/// A calendar date. Build it with `date(y, m, d)` to validate it; years may be 0 or negative
/// (proleptic Gregorian, astronomical numbering: year 0 is 1 BC).
pub struct Date { year: int, month: int, day: int }

/// A time of day, to the millisecond. Build it with `time(h, m, s, ms)` to validate it.
pub struct Time { hour: int, minute: int, second: int, ms: int }

/// An instant plus the fixed UTC offset used to display it. `ms` counts milliseconds since
/// 1970-01-01T00:00:00Z (leap seconds ignored, as in Unix time); `offset_min` is minutes east of
/// UTC (-1439..1439). `==` compares both fields; `<` and `sort` order by instant first.
pub struct DateTime { ms: int, offset_min: int }

pub enum Weekday { Mon, Tue, Wed, Thu, Fri, Sat, Sun }

/// A step for `add`. `Day` and `Week` are exact multiples of 24 hours (fixed offsets have no
/// daylight saving); `Month` and `Year` move the local calendar date and clamp the day to the
/// month's end (Jan 31 + 1 month = Feb 28 or 29).
pub enum Unit { Ms, Sec, Min, Hour, Day, Week, Month, Year }

/// Why parsing or validation failed. `col` is the 1-based char column of the problem.
pub enum DateErr {
  Syntax(expected: str, col: int),     // e.g. Syntax("2-digit month", 6)
  OutOfRange(field: str, value: int),  // e.g. OutOfRange("day", 30) for Feb 30
}

/// A one-line description of an error, e.g. `col 6: expected 2-digit month`.
pub fn message(e: DateErr): str
fn message(Syntax(x, c)): str = "col {c}: expected {x}"
fn message(OutOfRange(f, v)): str = "{f} out of range: {v}"

/// The largest year magnitude `date` accepts (keeps every millisecond count far from overflow).
let MAX_YEAR = 999_999
let MS_SEC = 1000
let MS_MIN = 60_000
let MS_HOUR = 3_600_000
let MS_DAY = 86_400_000

let WEEKDAYS = [Mon, Tue, Wed, Thu, Fri, Sat, Sun]
let DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
let DAY_ABBRS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

let MONTH_NAMES = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
]

let MONTH_ABBRS = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
]

// "00" to "99" and "000" to "999": zero-padded numbers ready-made, for formatting
imprint PAD2 = (0..100).map(i => "{i:02}")
imprint PAD3 = (0..1000).map(i => "{i:03}")

// `"{v:02}"` and `"{v:03}"`
fn pad2(v: int): str = if v >= 0 && v < 100 { PAD2[v] } else { "{v:02}" }
fn pad3(v: int): str = if v >= 0 && v < 1000 { PAD3[v] } else { "{v:03}" }

// Floor division and modulo (Auk's `/` and `%` truncate toward zero). b > 0.
fn fdiv(a: int, b: int): int = if a < 0 && a % b != 0 { a / b - 1 } else { a / b }
fn fmod(a: int, b: int): int = a - fdiv(a, b) * b

// ---- calendar ----

/// Gregorian leap year: divisible by 4, except centuries not divisible by 400.
pub fn is_leap(year: int): bool = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)

/// 28..31.
pub fn days_in_month(year: int, month: int): int
  requires month >= 1 && month <= 12
{
  if month == 2 { return if is_leap(year) { 29 } else { 28 } }
  if month == 4 || month == 6 || month == 9 || month == 11 { 30 } else { 31 }
}

/// A validated date: month 1..12, day within the month, |year| <= 999,999.
pub fn date(year: int, month: int, day: int): Date!DateErr {
  if year < -MAX_YEAR || year > MAX_YEAR { fail(OutOfRange("year", year)) }
  if month < 1 || month > 12 { fail(OutOfRange("month", month)) }
  if day < 1 || day > days_in_month(year, month) { fail(OutOfRange("day", day)) }
  Date { year, month, day }
}

/// A validated time of day: 0..23, 0..59, 0..59 (no leap second 60), 0..999.
pub fn time(hour: int, minute: int, second: int, ms: int): Time!DateErr {
  if hour < 0 || hour > 23 { fail(OutOfRange("hour", hour)) }
  if minute < 0 || minute > 59 { fail(OutOfRange("minute", minute)) }
  if second < 0 || second > 59 { fail(OutOfRange("second", second)) }
  if ms < 0 || ms > 999 { fail(OutOfRange("ms", ms)) }
  Time { hour, minute, second, ms }
}

/// Days since 1970-01-01 (negative before it). Howard Hinnant's days_from_civil.
pub fn days(d: Date): int {
  let y = if d.month <= 2 { d.year - 1 } else { d.year }
  let era = fdiv(y, 400)
  let yoe = y - era * 400                                       // 0..399
  let mp = if d.month > 2 { d.month - 3 } else { d.month + 9 }  // March = 0
  let doy = (153 * mp + 2) / 5 + d.day - 1                      // 0..365
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy               // 0..146096
  era * 146_097 + doe - 719_468
}

/// The date `n` days after 1970-01-01 (the inverse of `days`).
pub fn from_days(n: int): Date {
  let z = n + 719_468
  let era = fdiv(z, 146_097)
  let doe = z - era * 146_097
  let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let day = doy - (153 * mp + 2) / 5 + 1
  let month = if mp < 10 { mp + 3 } else { mp - 9 }
  let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 }
  Date { year, month, day }
}

/// The day of the week.
pub fn weekday(d: Date): Weekday = WEEKDAYS[fmod(days(d) + 3, 7)]  // 1970-01-01 was a Thursday
/// The day of the week in `d`'s own offset.
pub fn weekday(d: DateTime): Weekday = weekday(date(d))

/// ISO 8601 day number: Mon = 1 .. Sun = 7.
pub fn number(w: Weekday): int = match w {
  Mon => 1
  Tue => 2
  Wed => 3
  Thu => 4
  Fri => 5
  Sat => 6
  Sun => 7
}

/// 1..366.
pub fn day_of_year(d: Date): int = days(d) - days(Date { month: 1, day: 1, ..d }) + 1

pub fn add_days(d: Date, n: int): Date = from_days(days(d) + n)

/// Moves by whole months, clamping the day to the target month's length.
pub fn add_months(d: Date, n: int): Date {
  let total = d.year * 12 + d.month - 1 + n
  let year = fdiv(total, 12)
  let month = fmod(total, 12) + 1
  let last = days_in_month(year, month)
  Date { year, month, day: if d.day > last { last } else { d.day } }
}

/// Whole days from `b` to `a` (`a - b`).
pub fn diff(a: Date, b: Date): int = days(a) - days(b)

pub fn cmp(a: Date, b: Date): int = days(a) - days(b)
pub fn cmp(a: Time, b: Time): int = ms_of_day(a) - ms_of_day(b)

// ---- instants ----

/// The instant `ms` milliseconds after the Unix epoch, shown in UTC.
pub fn from_unix_ms(ms: int): DateTime = DateTime { ms, offset_min: 0 }

/// Milliseconds since the Unix epoch.
pub fn unix_ms(d: DateTime): int = d.ms

/// The same instant, shown in UTC.
pub fn utc(d: DateTime): DateTime = DateTime { offset_min: 0, ..d }

/// A UTC instant from calendar fields (validated): `datetime.utc(2024, 2, 29, 13, 5, 0)?`.
pub fn utc(year: int, month: int, day: int, hour: int, minute: int, second: int): DateTime!DateErr =
  make(date(year, month, day)?, time(hour, minute, second, 0)?, 0)

/// The same instant, shown at a fixed offset of `minutes` east of UTC (-1439..1439).
pub fn with_offset(d: DateTime, minutes: int): DateTime!DateErr {
  check_offset(minutes)?
  DateTime { offset_min: minutes, ..d }
}

fn check_offset(m: int): ()!DateErr {
  if m <= -1440 || m >= 1440 { fail(OutOfRange("offset", m)) }
}

/// The instant whose local date and time at `offset_min` are `d` and `t` (both re-validated).
pub fn make(d: Date, t: Time, offset_min: int): DateTime!DateErr {
  date(d.year, d.month, d.day)?
  time(t.hour, t.minute, t.second, t.ms)?
  check_offset(offset_min)?
  DateTime { ms: days(d) * MS_DAY + ms_of_day(t) - offset_min * MS_MIN, offset_min }
}

fn ms_of_day(t: Time): int = t.hour * MS_HOUR + t.minute * MS_MIN + t.second * MS_SEC + t.ms

// Milliseconds since the epoch of the local wall clock.
fn local(d: DateTime): int = d.ms + d.offset_min * MS_MIN

/// The local calendar date at `d`'s offset.
pub fn date(d: DateTime): Date = from_days(fdiv(local(d), MS_DAY))

/// The local time of day at `d`'s offset.
pub fn time(d: DateTime): Time {
  let t = fmod(local(d), MS_DAY)
  Time {
    hour: t / MS_HOUR,
    minute: t / MS_MIN % 60,
    second: t / MS_SEC % 60,
    ms: t % MS_SEC,
  }
}

/// `n` units later (negative `n`: earlier). See `Unit` for how months and years clamp.
pub fn add(d: DateTime, n: int, u: Unit): DateTime = match u {
  Ms => shift(d, n)
  Sec => shift(d, n * MS_SEC)
  Min => shift(d, n * MS_MIN)
  Hour => shift(d, n * MS_HOUR)
  Day => shift(d, n * MS_DAY)
  Week => shift(d, n * 7 * MS_DAY)
  Month => on_date(d, add_months(date(d), n))
  Year => on_date(d, add_months(date(d), n * 12))
}

fn shift(d: DateTime, by: int): DateTime = DateTime { ms: d.ms + by, ..d }

// `d`'s local time of day on another local date.
fn on_date(d: DateTime, day: Date): DateTime =
  DateTime { ms: days(day) * MS_DAY + ms_of_day(time(d)) - d.offset_min * MS_MIN, ..d }

/// Milliseconds from `b` to `a` (`a - b`); offsets don't matter.
pub fn diff(a: DateTime, b: DateTime): int = a.ms - b.ms

/// Orders by instant, then by offset (so `cmp` is 0 exactly when `==`).
pub fn cmp(a: DateTime, b: DateTime): int {
  if a.ms != b.ms { return if a.ms < b.ms { -1 } else { 1 } }
  a.offset_min - b.offset_min
}

// ---- formatting ----

/// `2024-02-29`; years outside 0..9999 get a sign (`-0044-03-15`, `+10000-01-01`).
pub fn show(d: Date): str {
  var out = year_str(d.year)
  add_date(&out, d)
  out
}
/// `13:05:09`, or `13:05:09.120` when the milliseconds aren't zero.
pub fn show(t: Time): str {
  var out = pad2(t.hour)
  add_time(&out, t)
  out
}
/// RFC 3339: `2024-02-29T13:05:09.120Z`, `1996-12-19T16:39:57-08:00`. Milliseconds are omitted
/// when zero; offset 0 is written `Z`.
pub fn show(d: DateTime): str {
  let day = date(d)
  let t = time(d)
  var out = year_str(day.year)
  add_date(&out, day)
  out += "T"
  out += pad2(t.hour)
  add_time(&out, t)
  out += offset_str(d.offset_min, ":")
  out
}

// Appends `-MM-DD` (what follows the year).
fn add_date(out: var str, d: Date) {
  out += "-"
  out += pad2(d.month)
  out += "-"
  out += pad2(d.day)
}

// Appends `:mm:ss[.fff]` (what follows the hour).
fn add_time(out: var str, t: Time) {
  out += ":"
  out += pad2(t.minute)
  out += ":"
  out += pad2(t.second)
  if t.ms != 0 {
    out += "."
    out += pad3(t.ms)
  }
}

fn year_str(y: int): str when y < 0 = "-{-y:04}"
fn year_str(y: int): str when y > 9999 = "+{y}"
fn year_str(y: int): str = PAD2[y / 100] + PAD2[y % 100]

// "Z" for 0 with ":" (RFC 3339); "+0000" style with "" (strftime %z).
fn offset_str(0, ":"): str = "Z"
fn offset_str(m: int, sep: str): str {
  let a = m.abs()
  var out = if m < 0 { "-" } else { "+" }
  out += pad2(a / 60)
  out += sep
  out += pad2(a % 60)
  out
}

/// Formats with strftime-style directives: `%Y` year, `%m` month, `%d` day, `%H` hour, `%M`
/// minute, `%S` second, `%L` milliseconds (3 digits), `%j` day of year (3 digits), `%a`/`%A`
/// weekday (`Mon`/`Monday`), `%b`/`%B` month (`Jan`/`January`), `%u` ISO weekday 1..7, `%s`
/// Unix seconds, `%z` offset `+0530`, `%Z` offset `Z`/`+05:30`, `%%` a percent sign. Anything
/// else is copied as is. Fields are local to `d`'s offset.
pub fn format(d: DateTime, pattern: str): str {
  let day = date(d)
  let t = time(d)
  let cs = pattern.chars()
  var out = ""
  var i = 0
  var lit = 0  // where the text not yet copied starts
  while i < cs.len() {
    if cs[i] == '%' && i + 1 < cs.len() {
      if i > lit { out += str(cs[lit..i]) }
      out += directive(cs[i + 1], d, day, t)
      i += 2
      lit = i
    } else {
      i += 1
    }
  }
  if cs.len() > lit { out += str(cs[lit..cs.len()]) }
  out
}

// `day` and `t` are `d`'s local date and time.
fn directive(c: char, d: DateTime, day: Date, t: Time): str = match c {
  'Y' => year_str(day.year)
  'm' => pad2(day.month)
  'd' => pad2(day.day)
  'H' => pad2(t.hour)
  'M' => pad2(t.minute)
  'S' => pad2(t.second)
  'L' => pad3(t.ms)
  'j' => pad3(day_of_year(day))
  'a' => DAY_ABBRS[fmod(days(day) + 3, 7)]
  'A' => DAY_NAMES[fmod(days(day) + 3, 7)]
  'b' => MONTH_ABBRS[day.month - 1]
  'B' => MONTH_NAMES[day.month - 1]
  'u' => "{fmod(days(day) + 3, 7) + 1}"
  's' => "{fdiv(d.ms, MS_SEC)}"
  'z' => if d.offset_min == 0 { "+0000" } else { offset_str(d.offset_min, "") }
  'Z' => offset_str(d.offset_min, ":")
  '%' => "%"
  _ => "%{c}"
}

/// The HTTP date format (RFC 9110 IMF-fixdate), always in GMT: `Sun, 06 Nov 1994 08:49:37 GMT`.
pub fn http_date(d: DateTime): str = format(utc(d), "%a, %d %b %Y %H:%M:%S GMT")

// ---- parsing ----

struct P { cs: [char], i: int }

/// Parses an RFC 3339 / ISO 8601 timestamp: `YYYY-MM-DD`, then `T`, `t` or a space,
/// `hh:mm[:ss[.fff]]`, then `Z`, `z`, `±hh:mm`, `±hhmm` or `±hh`. A fraction may have any number
/// of digits (truncated to milliseconds; `,` also works). A date alone means midnight UTC.
/// The offset is otherwise required, and leap second `:60` is rejected.
pub fn parse(s: str): DateTime!DateErr {
  var p = P { cs: s.chars(), i: 0 }
  let d = date_part(&p)?
  if p.done() { return make(d, Time { hour: 0, minute: 0, second: 0, ms: 0 }, 0) }
  if !p.eat('T') && !p.eat('t') && !p.eat(' ') { fail(p.want("'T'")) }
  let t = time_part(&p)?
  let off = offset(&p)?
  if !p.done() { fail(p.want("end of input")) }
  make(d, t, off)
}

/// Parses a calendar date `YYYY-MM-DD`.
pub fn parse_date(s: str): Date!DateErr {
  var p = P { cs: s.chars(), i: 0 }
  let d = date_part(&p)?
  if !p.done() { fail(p.want("end of input")) }
  d
}

/// Parses a time of day `hh:mm[:ss[.fff]]` (no offset).
pub fn parse_time(s: str): Time!DateErr {
  var p = P { cs: s.chars(), i: 0 }
  let t = time_part(&p)?
  if !p.done() { fail(p.want("end of input")) }
  t
}

fn done(p: P): bool = p.i >= p.cs.len()
fn want(p: P, what: str): DateErr = Syntax(what, p.i + 1)
fn digit_at(p: P): bool = p.i < p.cs.len() && p.cs[p.i] >= '0' && p.cs[p.i] <= '9'

fn eat(p: var P, c: char): bool {
  if p.i < p.cs.len() && p.cs[p.i] == c {
    p.i += 1
    return true
  }
  false
}

fn expect(p: var P, c: char): ()!DateErr {
  if !p.eat(c) { fail(p.want("'{c}'")) }
}

// exactly n ASCII digits; an error points at the first of them
fn num(p: var P, n: int, what: str): int!DateErr {
  let start = p.i
  var v = 0
  for _ in 0..n {
    if !p.digit_at() { fail(Syntax("{n}-digit {what}", start + 1)) }
    v = v * 10 + int(p.cs[p.i]) - int('0')
    p.i += 1
  }
  v
}

fn date_part(p: var P): Date!DateErr {
  let y = num(&p, 4, "year")?
  expect(&p, '-')?
  let m = num(&p, 2, "month")?
  expect(&p, '-')?
  let d = num(&p, 2, "day")?
  date(y, m, d)
}

fn time_part(p: var P): Time!DateErr {
  let h = num(&p, 2, "hour")?
  expect(&p, ':')?
  let m = num(&p, 2, "minute")?
  var s = 0
  var ms = 0
  if p.eat(':') {
    s = num(&p, 2, "second")?
    if p.eat('.') || p.eat(',') {
      if !p.digit_at() { fail(p.want("fraction digits")) }
      var scale = 100
      while p.digit_at() {
        ms += (int(p.cs[p.i]) - int('0')) * scale
        scale /= 10
        p.i += 1
      }
    }
  }
  time(h, m, s, ms)
}

fn offset(p: var P): int!DateErr {
  if p.eat('Z') || p.eat('z') { return 0 }
  let sign = if p.eat('+') {
    1
  } else if p.eat('-') {
    -1
  } else {
    fail(p.want("'Z' or a UTC offset"))
  }
  let h = num(&p, 2, "offset hour")?
  var m = 0
  if p.eat(':') {
    m = num(&p, 2, "offset minute")?
  } else if p.digit_at() {
    m = num(&p, 2, "offset minute")?
  }
  if h > 23 { fail(OutOfRange("offset hour", h)) }
  if m > 59 { fail(OutOfRange("offset minute", m)) }
  sign * (h * 60 + m)
}

// ---- tests ----

test "floor division helpers" {
  assert (fdiv(7, 2), fdiv(-7, 2), fdiv(-8, 2), fdiv(0, 5)) == (3, -4, -4, 0)
  assert (fmod(7, 3), fmod(-7, 3), fmod(-6, 3)) == (1, 2, 0)
}

test "leap years and month lengths" {
  assert is_leap(2000) && is_leap(2024) && is_leap(1600) && is_leap(0) && is_leap(-4)
  assert !is_leap(1900) && !is_leap(2100) && !is_leap(2023) && !is_leap(-1)
  assert days_in_month(2024, 2) == 29
  assert days_in_month(2023, 2) == 28
  assert days_in_month(1900, 2) == 28
  assert [1, 3, 5, 7, 8, 10, 12].all(m => days_in_month(2023, m) == 31)
  assert [4, 6, 9, 11].all(m => days_in_month(2023, m) == 30)
}

test "validated constructors" {
  assert date(2024, 2, 29)? == Date { year: 2024, month: 2, day: 29 }
  assert date(2023, 2, 29) is err(OutOfRange("day", 29))
  assert date(2024, 2, 30) is err(OutOfRange("day", 30))
  assert date(2024, 13, 1) is err(OutOfRange("month", 13))
  assert date(2024, 0, 1) is err(OutOfRange("month", 0))
  assert date(2024, 4, 31) is err(OutOfRange("day", 31))
  assert date(2024, 1, 0) is err(OutOfRange("day", 0))
  assert date(1_000_000, 1, 1) is err(OutOfRange("year", 1_000_000))
  assert date(-44, 3, 15) is ok(_)
  assert time(23, 59, 59, 999)? == Time { hour: 23, minute: 59, second: 59, ms: 999 }
  assert time(24, 0, 0, 0) is err(OutOfRange("hour", 24))
  assert time(12, 60, 0, 0) is err(OutOfRange("minute", 60))
  assert time(23, 59, 60, 0) is err(OutOfRange("second", 60))
  assert time(0, 0, 0, 1000) is err(OutOfRange("ms", 1000))
  assert time(-1, 0, 0, 0) is err(OutOfRange("hour", -1))
}

test "days from civil, known values" {
  assert days(date(1970, 1, 1)?) == 0
  assert days(date(1969, 12, 31)?) == -1
  assert days(date(2000, 2, 29)?) == 11_016
  assert days(date(2000, 3, 1)?) == 11_017
  assert days(date(9999, 12, 31)?) == 2_932_896
  assert days(date(1, 1, 1)?) == -719_162
  assert days(date(0, 3, 1)?) == -719_468
  assert from_days(0) == Date { year: 1970, month: 1, day: 1 }
  assert from_days(-1) == Date { year: 1969, month: 12, day: 31 }
  assert from_days(11_016) == Date { year: 2000, month: 2, day: 29 }
  assert from_days(-719_469) == Date { year: 0, month: 2, day: 29 }  // year 0 is a leap year
  assert from_days(-719_528) == Date { year: 0, month: 1, day: 1 }
  assert from_days(-719_529) == Date { year: -1, month: 12, day: 31 }
}

test "civil round trip over ten thousand years" {
  var prev = from_days(-1_500_000)
  var n = -1_499_999
  while n < 3_000_000 {
    let d = from_days(n)
    assert days(d) == n
    let next_day = d.day == prev.day + 1 && d.month == prev.month && d.year == prev.year
    let next_month = d.day == 1 &&
      d.month == prev.month + 1 &&
      d.year == prev.year &&
      prev.day == days_in_month(prev.year, prev.month)
    let next_year =
      (d.year, d.month, d.day) == (prev.year + 1, 1, 1) && (prev.month, prev.day) == (12, 31)
    assert next_day || next_month || next_year
    prev = d
    n += 1
  }
}

test "weekdays" {
  assert weekday(date(1970, 1, 1)?) == Thu
  assert weekday(date(2000, 1, 1)?) == Sat
  assert weekday(date(2024, 2, 29)?) == Thu
  assert weekday(date(1900, 1, 1)?) == Mon
  assert weekday(date(1969, 12, 28)?) == Sun
  assert weekday(date(1, 1, 1)?) == Mon
  assert number(Mon) == 1 && number(Sun) == 7
  // the same instant is a different local day across the date line
  let t = parse("2024-03-03T23:30:00Z")?
  assert weekday(t) == Sun
  assert weekday(t.with_offset(60)?) == Mon
}

test "day of year" {
  assert day_of_year(date(2024, 1, 1)?) == 1
  assert day_of_year(date(2024, 12, 31)?) == 366
  assert day_of_year(date(2023, 12, 31)?) == 365
  assert day_of_year(date(1994, 11, 6)?) == 310
}

test "date arithmetic" {
  let d = date(2024, 1, 31)?
  assert add_days(d, 1) == date(2024, 2, 1)?
  assert add_days(d, -31) == date(2023, 12, 31)?
  assert add_days(d, 366) == date(2025, 1, 31)?
  assert add_months(d, 1) == date(2024, 2, 29)?  // clamped
  assert add_months(date(2023, 1, 31)?, 1) == date(2023, 2, 28)?
  assert add_months(d, 3) == date(2024, 4, 30)?
  assert add_months(d, -2) == date(2023, 11, 30)?
  assert add_months(d, 12) == date(2025, 1, 31)?
  assert add_months(d, -25) == date(2021, 12, 31)?
  assert add_months(date(2024, 2, 29)?, 12) == date(2025, 2, 28)?
  assert add_months(date(1, 1, 15)?, -13) == date(-1, 12, 15)?
  assert diff(date(2024, 3, 1)?, date(2024, 2, 1)?) == 29
  assert diff(date(1970, 1, 1)?, date(2000, 1, 1)?) == -10_957
  assert date(2024, 1, 1)? < date(2024, 1, 2)?
  assert [date(2024, 5, 1)?, date(1999, 1, 1)?, date(2024, 4, 30)?].sort() ==
    [date(1999, 1, 1)?, date(2024, 4, 30)?, date(2024, 5, 1)?]
}

test "instants and local fields" {
  let e = from_unix_ms(0)
  assert date(e) == date(1970, 1, 1)?
  assert time(e) == time(0, 0, 0, 0)?
  let before = from_unix_ms(-1)
  assert date(before) == date(1969, 12, 31)?
  assert time(before) == time(23, 59, 59, 999)?
  let t = from_unix_ms(1_709_211_909_120)
  assert date(t) == date(2024, 2, 29)?
  assert time(t) == time(13, 5, 9, 120)?
  assert unix_ms(t) == 1_709_211_909_120
  let ist = t.with_offset(330)?
  assert unix_ms(ist) == unix_ms(t)
  assert time(ist) == time(18, 35, 9, 120)?
  assert ist != t && ist.utc() == t
  let ny = t.with_offset(-300)?
  assert time(ny) == time(8, 5, 9, 120)?
  assert t.with_offset(1440) is err(OutOfRange("offset", 1440))
  assert t.with_offset(-1440) is err(OutOfRange("offset", -1440))
  assert utc(2024, 2, 29, 13, 5, 9)? == from_unix_ms(1_709_211_909_000)
  assert utc(2024, 2, 30, 0, 0, 0) is err(OutOfRange("day", 30))
  assert (utc(9999, 12, 31, 23, 59, 59)?).unix_ms() == 253_402_300_799_000
  assert (utc(1, 1, 1, 0, 0, 0)?).unix_ms() == -62_135_596_800_000
  assert (utc(1969, 7, 20, 20, 17, 40)?).unix_ms() == -14_182_940_000
  let local = make(date(1996, 12, 19)?, time(16, 39, 57, 0)?, -480)?
  assert local.unix_ms() == 851_042_397_000
  assert make(
    Date { year: 2023, month: 2, day: 29 },
    time(0, 0, 0, 0)?,
    0,
  ) is err(OutOfRange("day", 29))
  assert make(
    date(2023, 2, 1)?,
    Time { hour: 25, minute: 0, second: 0, ms: 0 },
    0,
  ) is err(OutOfRange("hour", 25))
}

test "add and diff" {
  let t = parse("2024-01-31T10:00:00+02:00")?
  assert add(t, 1500, Ms).show() == "2024-01-31T10:00:01.500+02:00"
  assert add(t, 90, Sec).show() == "2024-01-31T10:01:30+02:00"
  assert add(t, -61, Min).show() == "2024-01-31T08:59:00+02:00"
  assert add(t, 14, Hour).show() == "2024-02-01T00:00:00+02:00"
  assert add(t, 1, Day).show() == "2024-02-01T10:00:00+02:00"
  assert add(t, -2, Week).show() == "2024-01-17T10:00:00+02:00"
  assert add(t, 1, Month).show() == "2024-02-29T10:00:00+02:00"
  assert add(t, 13, Month).show() == "2025-02-28T10:00:00+02:00"
  assert add(t, -1, Year).show() == "2023-01-31T10:00:00+02:00"
  // month arithmetic uses the local date: 23:30 UTC on Jan 31 is already Feb 1 at +01:00
  let late = parse("2024-01-31T23:30:00Z")?
  assert add(late, 1, Month).show() == "2024-02-29T23:30:00Z"
  assert add(late.with_offset(60)?, 1, Month).show() == "2024-03-01T00:30:00+01:00"
  assert diff(add(t, 3, Day), t) == 3 * 86_400_000
  assert diff(t, parse("2024-01-31T08:00:00Z")?) == 0
  assert parse("2024-01-31T08:00:00Z")? < parse("2024-01-31T08:00:01+00:00")?
  assert parse("2024-01-31T10:00:00+02:00")? > parse("2024-01-31T08:00:00Z")?
}

test "show" {
  assert "{date(2024, 2, 9)?}" == "2024-02-09"
  assert "{date(33, 1, 1)?}" == "0033-01-01"
  assert "{date(-44, 3, 15)?}" == "-0044-03-15"
  assert "{date(12345, 6, 7)?}" == "+12345-06-07"
  assert "{time(7, 5, 3, 0)?}" == "07:05:03"
  assert "{time(7, 5, 3, 4)?}" == "07:05:03.004"
  assert "{from_unix_ms(0)}" == "1970-01-01T00:00:00Z"
  assert "{from_unix_ms(1_709_211_909_120)}" == "2024-02-29T13:05:09.120Z"
  assert "{from_unix_ms(0).with_offset(-90)?}" == "1969-12-31T22:30:00-01:30"
  assert "{from_unix_ms(0).with_offset(345)?}" == "1970-01-01T05:45:00+05:45"
}

test "format patterns" {
  let t = parse("1994-11-06T08:49:37.250Z")?
  assert format(t, "%Y-%m-%d %H:%M:%S.%L") == "1994-11-06 08:49:37.250"
  assert format(t, "%a %A %b %B %j %u") == "Sun Sunday Nov November 310 7"
  assert format(t, "%s %z %Z %%Y %q 100%") == "784111777 +0000 Z %Y %q 100%"
  let k = t.with_offset(-570)?
  assert format(k, "%d/%m/%Y %H:%M %z %Z") == "05/11/1994 23:19 -0930 -09:30"
  assert format(from_unix_ms(-1), "%s") == "-1"
  assert format(t, "") == ""
}

test "http dates" {
  assert http_date(parse("1994-11-06T08:49:37Z")?) == "Sun, 06 Nov 1994 08:49:37 GMT"
  assert http_date(parse("1994-11-06T09:49:37+01:00")?) == "Sun, 06 Nov 1994 08:49:37 GMT"
  assert http_date(from_unix_ms(0)) == "Thu, 01 Jan 1970 00:00:00 GMT"
}

test "parse: RFC 3339 examples" {
  assert (parse("1985-04-12T23:20:50.52Z")?).unix_ms() == 482_196_050_520
  let pst = parse("1996-12-19T16:39:57-08:00")?
  assert (pst.unix_ms(), pst.offset_min) == (851_042_397_000, -480)
  assert "{pst}" == "1996-12-19T16:39:57-08:00"
  let odd = parse("1937-01-01T12:00:27.87+00:20")?
  assert (odd.unix_ms(), odd.offset_min) == (-1_041_337_172_130, 20)
  assert "{odd}" == "1937-01-01T12:00:27.870+00:20"
  assert parse("1990-12-31T23:59:60Z") is err(OutOfRange("second", 60))  // no leap seconds
}

test "parse: ISO 8601 variants" {
  let z = from_unix_ms(1_709_211_909_000)
  assert parse("2024-02-29T13:05:09Z")? == z
  assert parse("2024-02-29t13:05:09z")? == z
  assert parse("2024-02-29 13:05:09Z")? == z
  assert parse("2024-02-29T13:05:09+00:00")? == z
  assert parse("2024-02-29T13:05:09-00:00")? == z
  assert (parse("2024-02-29T18:35:09+0530")?).unix_ms() == z.unix_ms()
  assert (parse("2024-02-29T15:05:09+02")?).unix_ms() == z.unix_ms()
  assert parse("2024-02-29T13:05Z")? == utc(2024, 2, 29, 13, 5, 0)?
  assert (parse("2024-02-29T13:05:09.123456789Z")?).unix_ms() == z.unix_ms() + 123
  assert (parse("2024-02-29T13:05:09,5Z")?).unix_ms() == z.unix_ms() + 500
  assert parse("2024-02-29")? == utc(2024, 2, 29, 0, 0, 0)?
  for s in ["2024-02-29T13:05:09.120Z", "1969-12-31T23:59:59.999-23:59", "0000-01-01T00:00:00Z"] {
    assert "{parse(s)?}" == s
  }
}

test "parse: errors" {
  assert parse("") is err(Syntax("4-digit year", 1))
  assert parse("24-02-29") is err(Syntax("4-digit year", 1))
  assert parse("2024/02/29") is err(Syntax("'-'", 5))
  assert parse("2024-2-29") is err(Syntax("2-digit month", 6))
  assert parse("2024-13-01") is err(OutOfRange("month", 13))
  assert parse("2023-02-29") is err(OutOfRange("day", 29))
  assert parse("2024-02-30T00:00:00Z") is err(OutOfRange("day", 30))
  assert parse("2024-02-29X10:00Z") is err(Syntax("'T'", 11))
  assert parse("2024-02-29T10Z") is err(Syntax("':'", 14))
  assert parse("2024-02-29T25:00:00Z") is err(OutOfRange("hour", 25))
  assert parse("2024-02-29T10:00:00") is err(Syntax("'Z' or a UTC offset", 20))
  assert parse("2024-02-29T10:00:00.Z") is err(Syntax("fraction digits", 21))
  assert parse("2024-02-29T10:00:00+24:00") is err(OutOfRange("offset hour", 24))
  assert parse("2024-02-29T10:00:00+05:60") is err(OutOfRange("offset minute", 60))
  assert parse("2024-02-29T10:00:00+5") is err(Syntax("2-digit offset hour", 21))
  assert parse("2024-02-29T10:00:00Z ") is err(Syntax("end of input", 21))
  assert parse("2024-02-29T10:00:00Zjunk") is err(Syntax("end of input", 21))
  assert parse("２０２４-01-01") is err(Syntax("4-digit year", 1))  // ASCII digits only
}

test "parse_date and parse_time" {
  assert parse_date("2000-02-29")? == date(2000, 2, 29)?
  assert parse_date("1900-02-29") is err(OutOfRange("day", 29))
  assert parse_date("2000-02-29T00:00Z") is err(Syntax("end of input", 11))
  assert parse_time("07:30")? == time(7, 30, 0, 0)?
  assert parse_time("23:59:59.999")? == time(23, 59, 59, 999)?
  assert parse_time("23:59:59Z") is err(Syntax("end of input", 9))
  assert parse_time("7:30") is err(Syntax("2-digit hour", 1))
}

test "messages" {
  assert message(Syntax("2-digit month", 6)) == "col 6: expected 2-digit month"
  assert message(OutOfRange("day", 30)) == "day out of range: 30"
  let err(e) = parse("2024-02-30") else fail("expected an error")
  assert message(e) == "day out of range: 30"
}

// used by the Data test
struct Event { name: str, at: DateTime }

test "values are Data" {
  let ev = Event { name: "launch", at: parse("2024-02-29T13:05:09+01:00")? }
  let back: Event = from_value(to_value(ev))?
  assert back == ev
}
