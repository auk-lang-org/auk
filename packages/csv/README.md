# csv

Reads and writes RFC 4180 CSV. It handles quoted fields, doubled quotes (`""`), commas and line breaks inside quotes, and CRLF, LF or lone-CR line endings. It returns rows as `[[str]]` or, when the file has a header row, as maps keyed by column name. The writer quotes a field only when it needs to. `to_values`/`decode` connect header-keyed rows to your structs through the core `Value` tree. Errors are a typed `CsvErr` that carries the line and column.

**Effects:** none.

```auk
struct Item { name: str, qty: int, price: float }

let rows = csv.parse("a,\"b,c\"\r\n1,\"say \"\"hi\"\"\"\r\n")?   // [["a", "b,c"], ["1", "say \"hi\""]]
let recs = csv.records(fs.read("stock.csv")?)?                  // [{"name": "nut", "qty": "3", ...}]
let items: [Item] = csv.decode(fs.read("stock.csv")?)?
fs.write("out.csv", csv.write([["name", "note"], ["nut", "small, round"]]))?
```

## API
- `enum CsvErr { Unclosed(line, col), StrayQuote(line, col), AfterQuote(found: char, line, col), Ragged(row, want, got), DupHeader(name: str) }` (all numbers are `int` and 1-based)
- `parse(s: str): [[str]]!CsvErr`: rows of fields; rows can have different lengths, and a blank line becomes `[""]`
- `records(s: str): [{str: str}]!CsvErr`: the first row is the header; blank lines are skipped; a row whose field count doesn't match the header is an error
- `write(rows: [[str]]): str`: rows end in CRLF; a field is quoted only if it contains `,`, `"`, CR or LF
- `write_records(header: [str], recs: [{str: str}]): str`: writes the header, then each row's values in header order
- `to_values(recs: [{str: str}]): [Value]`: one `Map` per row; each cell becomes `Bool`, `Int`, `Float` or `Str` depending on its text (`007` stays `Str`)
- `decode<T: Data>(s: str): [T]!`: `records` + `to_values` + the derived `from_value`
- `message(e: CsvErr): str`: a one-line description of the error
