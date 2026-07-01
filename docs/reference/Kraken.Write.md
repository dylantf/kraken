---
title: Kraken.Write
---

## Types

### InsertCell

```saga
type InsertCell =
  | Bind String InsertValue
  | Skip
```

### InsertInput

```saga
opaque type InsertInput slot
```

### InsertFields

```saga
opaque type InsertFields row
```

### Insert

```saga
type Insert =
  | Insert
```

### Writer

```saga
opaque type Writer cols input
```

## Effects

### Update

```saga
effect Update {
  fun set : Col a -> a -> Unit where {a: PgType}
  fun where_ : Expr -> Unit
}
```

The UPDATE builder DSL. Use `set!` and `where_!` inside the closure passed to
`update`. This is the surgical update path: you write only the columns that
change, so it stays compact even on wide tables.

## Functions

### insert_value

```saga
fun insert_value : a -> InsertInput (Col a) where {a: PgType}
```

### insert_default

```saga
fun insert_default : InsertInput (Col a)
```

### insert_auto

```saga
fun insert_auto : InsertInput (Generated a)
```

### insert_generated

```saga
fun insert_generated : GeneratedValue a -> InsertInput (Generated a) where {a: PgType}
```

### insert_into

```saga
fun insert_into : row -> InsertFields row
```

### insert_field

```saga
fun insert_field : String -> InsertInput slot -> InsertFields (slot -> row) -> InsertFields row
```

### writer

```saga
fun writer : cols -> input -> List InsertCell -> Writer cols input
```

### set

```saga
fun set : Col a -> a -> InsertCell where {a: PgType}
```

### set_default

```saga
fun set_default : Col a -> DefaultValue a -> InsertCell where {a: PgType}
```

### set_generated

```saga
fun set_generated : Generated a -> GeneratedValue a -> InsertCell where {a: PgType}
```

### insert

```saga
fun insert : Table cols -> Writer cols input -> input -> Prepared Unit
```

Build an INSERT statement using a table-specific writer. Column names come
from the writer's column handles; `Skip` cells are omitted.

### insert_record

```saga
fun insert_record : Table cols -> InsertFields row -> Prepared Unit where {cols: ColumnSet}
```

Build an INSERT from an anonymous record builder:

Db.insert_record users build Db.Insert Users {
id: Db.insert_auto,
name: Db.insert_value "Carol",
age: Db.insert_value 31,
}

Use the table's column record (`Users` here) as the `Db.InsertFields` shape to
make the compiler check that every field is present. Field labels map to SQL
names via `ColumnSet.column_names` (identity by default).

### insert_returning

```saga
fun insert_returning : Table cols -> Writer cols input -> input -> cols -> Projection row -> Prepared row
```

Like `insert`, but appends a `RETURNING` clause built from the projection
callback (the table's columns are passed in, exactly like `select`). The result
is a `Prepared row`; run it with `Db.one` (single insert) or `Db.all`.

### insert_record_returning

```saga
fun insert_record_returning : Table cols -> InsertFields insert_row -> cols -> Projection row -> Prepared row where {cols: ColumnSet}
```

Like `insert_record`, but appends a `RETURNING` clause.

### insert_all

```saga
fun insert_all : Table cols -> Writer cols input -> List input -> Prepared Unit
```

Bulk insert: one `INSERT … VALUES (…), (…), …` statement for a list of rows.
A single round trip instead of one per row — meaningful over a network, where
a per-row loop (even inside a transaction) pays N round trips. Column names and
value order come from the writer, exactly like `insert`.

An empty list is a no-op: there is no valid zero-row VALUES SQL, so this returns
a `noop` `Prepared` that `Db.exec` short-circuits to `Ok 0` (and `Db.all` to
`Ok []`) without a database round trip — no call-site guard needed.

Note Postgres caps a statement at 65535 bind parameters, so a single call is
limited to ~`floor(65535 / columns)` rows — chunk larger batches caller-side.

### insert_all_records

```saga
fun insert_all_records : Table cols -> List (InsertFields row) -> Prepared Unit where {cols: ColumnSet}
```

Bulk insert for the record-builder insert path. Each row must have the same
field set; use `insert_default` / `insert_auto` when a row should ask Postgres
for a default without changing the shared column list.

### insert_all_returning

```saga
fun insert_all_returning : Table cols -> Writer cols input -> List input -> cols -> Projection row -> Prepared row
```

Like `insert_all`, but appends a `RETURNING` clause built from the projection
callback (the table's columns, exactly like `select`). Yields a `Prepared row`
with one row per inserted row; run it with `Db.all`. An empty list is a no-op
that `Db.all` short-circuits to `Ok []` (no round trip).

### insert_all_records_returning

```saga
fun insert_all_records_returning : Table cols -> List (InsertFields insert_row) -> cols -> Projection row -> Prepared row where {cols: ColumnSet}
```

Like `insert_all_records`, but appends a `RETURNING` clause.

### insert_on_conflict_do_nothing

```saga
fun insert_on_conflict_do_nothing : Table cols -> Writer cols input -> input -> cols -> List ColRef -> Prepared Unit
```

`INSERT ... ON CONFLICT (<target>) DO NOTHING` — insert the row unless it would
collide on the target columns, in which case skip it silently. The target
callback names the conflict columns with `Db.ref` (e.g. `fun u -> [Db.ref u.email]`).

### insert_record_on_conflict_do_nothing

```saga
fun insert_record_on_conflict_do_nothing : Table cols -> InsertFields row -> cols -> List ColRef -> Prepared Unit where {cols: ColumnSet}
```

Record-builder variant of `insert_on_conflict_do_nothing`.

### upsert

```saga
fun upsert : Table cols -> Writer cols input -> input -> cols -> List ColRef -> Prepared Unit
```

Upsert: `INSERT ... ON CONFLICT (<target>) DO UPDATE SET <rest> = EXCLUDED.<rest>`.
On a collision on the target columns, overwrite every *other* inserted column
with the value from this insert. The target callback names the conflict columns
with `Db.ref`. Panics at build time if the target covers every inserted column
(nothing left to update — use `insert_on_conflict_do_nothing`).

### upsert_record

```saga
fun upsert_record : Table cols -> InsertFields row -> cols -> List ColRef -> Prepared Unit where {cols: ColumnSet}
```

Record-builder variant of `upsert`.

### insert_on_conflict_do_nothing_returning

```saga
fun insert_on_conflict_do_nothing_returning : Table cols -> Writer cols input -> input -> cols -> List ColRef -> cols -> Projection row -> Prepared row
```

Like `insert_on_conflict_do_nothing`, but appends a `RETURNING` clause. Note a
skipped (conflicting) row produces *no* returned row, so `Db.one` yields
`Ok Nothing` on conflict.

### insert_record_on_conflict_do_nothing_returning

```saga
fun insert_record_on_conflict_do_nothing_returning : Table cols -> InsertFields insert_row -> cols -> List ColRef -> cols -> Projection row -> Prepared row where {cols: ColumnSet}
```

Record-builder returning variant of `insert_on_conflict_do_nothing`.

### upsert_returning

```saga
fun upsert_returning : Table cols -> Writer cols input -> input -> cols -> List ColRef -> cols -> Projection row -> Prepared row
```

Like `upsert`, but appends a `RETURNING` clause built from the projection
callback. Both the inserted and the updated row are returned, so `Db.one`
always yields the resulting row.

### upsert_record_returning

```saga
fun upsert_record_returning : Table cols -> InsertFields insert_row -> cols -> List ColRef -> cols -> Projection row -> Prepared row where {cols: ColumnSet}
```

Record-builder returning variant of `upsert`.

### upsert_set

```saga
fun upsert_set : Table cols -> Writer cols input -> input -> cols -> ConflictTarget -> cols -> List SetExpr -> Prepared Unit
```

Upsert with an explicit `DO UPDATE SET`: update only the columns you list, to
arbitrary expressions over the existing row, the proposed row (`Db.excluded`),
and literals — e.g. a counter `Db.assign u.count (Db.add u.count 1)` or a merge
`Db.assign u.total (Db.add_sql u.total (Db.excluded u.total))`. The conflict
target is a `Db.ConflictTarget` (`Db.on_columns [Db.ref u.id]` or
`Db.on_constraint "…"`). For the "overwrite every other column with EXCLUDED"
default, use `upsert` instead.

### upsert_record_set

```saga
fun upsert_record_set : Table cols -> InsertFields row -> cols -> ConflictTarget -> cols -> List SetExpr -> Prepared Unit where {cols: ColumnSet}
```

Record-builder variant of `upsert_set`.

### upsert_set_returning

```saga
fun upsert_set_returning : Table cols -> Writer cols input -> input -> cols -> ConflictTarget -> cols -> List SetExpr -> cols -> Projection row -> Prepared row
```

Like `upsert_set`, but appends a `RETURNING` clause built from the projection
callback. Yields the resulting row (inserted or updated) via `Db.one`.

### upsert_record_set_returning

```saga
fun upsert_record_set_returning : Table cols -> InsertFields insert_row -> cols -> ConflictTarget -> cols -> List SetExpr -> cols -> Projection row -> Prepared row where {cols: ColumnSet}
```

Record-builder returning variant of `upsert_set`.

### update

```saga
fun update : Table cols -> cols -> Unit needs {Update} -> Prepared Unit
```

Build an UPDATE statement. Columns are referenced through the callback's
column record; `set!`/`where_!` describe the assignments and row filter.

### update_returning

```saga
fun update_returning : Table cols -> cols -> Unit needs {Update} -> cols -> Projection row -> Prepared row
```

Like `update`, but appends a `RETURNING` clause built from the projection
callback. Returns a `Prepared row`; run it with `Db.all` / `Db.one`.

### update_all

```saga
fun update_all : Table cols -> Writer cols row -> row -> Prepared Unit where {cols: ColumnSet}
```

Save a whole entity: `UPDATE <table> SET <every non-key column> WHERE <pk>`.
The entity is the domain record as-is (read → modify → save, no conversion);
the key columns come from the table's `primary_key` and form the `WHERE`, the
rest become the `SET`. The supplied writer ties the accepted entity type to
the table's columns.

### delete

```saga
fun delete : Table cols -> cols -> Expr -> Prepared Unit
```

Build a DELETE statement. The predicate callback receives the table's columns.

### delete_returning

```saga
fun delete_returning : Table cols -> cols -> Expr -> cols -> Projection row -> Prepared row
```

Like `delete`, but appends a `RETURNING` clause built from the projection
callback. Returns a `Prepared row`; run it with `Db.all` / `Db.one`.

### exec

```saga
fun exec : Connection -> Prepared Unit -> Result Int DbError needs {Repo}
```

Execute a non-returning DML statement and return the number of affected rows.
For statements with `RETURNING`, decode rows with `Db.all` / `Db.one`
instead.

