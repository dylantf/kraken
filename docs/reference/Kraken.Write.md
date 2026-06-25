---
title: Kraken.Write
---

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

### insert

```saga
fun insert : Table cols -> ins -> Prepared Unit where {cols: Insertable ins + ColumnNameMap, ins: InsertRow}
```

Build an INSERT statement from a dedicated insert record. The input must be a
named type deriving `Db.InsertRow` (anonymous records are rejected, so a typo'd
or wrong-typed field fails to typecheck against that type). Column names come
from the record's fields; declare the columns you want to set and omit the
rest (e.g. DB-generated ones).

### insert_returning

```saga
fun insert_returning : Table cols -> ins -> cols -> selection -> Prepared row where {cols: Insertable ins + ColumnNameMap, ins: InsertRow, selection: Generic selection_rep, selection_rep: Selectable row_rep, row: Generic row_rep}
```

Like `insert`, but appends a `RETURNING` clause built from the projection
callback (the table's columns are passed in, exactly like `select`). The result
is a `Prepared row`; run it with `Db.one` (single insert) or `Db.all`.

### insert_all

```saga
fun insert_all : Table cols -> List ins -> Prepared Unit where {cols: Insertable ins + ColumnNameMap, ins: InsertRow}
```

Bulk insert: one `INSERT … VALUES (…), (…), …` statement for a list of rows.
A single round trip instead of one per row — meaningful over a network, where
a per-row loop (even inside a transaction) pays N round trips. Column names and
value order come from the synthesized insert record, exactly like `insert`.

An empty list is a no-op: there is no valid zero-row VALUES SQL, so this returns
a `noop` `Prepared` that `Db.exec` short-circuits to `Ok 0` (and `Db.all` to
`Ok []`) without a database round trip — no call-site guard needed.

Note Postgres caps a statement at 65535 bind parameters, so a single call is
limited to ~`floor(65535 / columns)` rows — chunk larger batches caller-side.

### insert_all_returning

```saga
fun insert_all_returning : Table cols -> List ins -> cols -> selection -> Prepared row where {cols: Insertable ins + ColumnNameMap, ins: InsertRow, selection: Generic selection_rep, selection_rep: Selectable row_rep, row: Generic row_rep}
```

Like `insert_all`, but appends a `RETURNING` clause built from the projection
callback (the table's columns, exactly like `select`). Yields a `Prepared row`
with one row per inserted row; run it with `Db.all`. An empty list is a no-op
that `Db.all` short-circuits to `Ok []` (no round trip).

### insert_on_conflict_do_nothing

```saga
fun insert_on_conflict_do_nothing : Table cols -> ins -> cols -> List ColRef -> Prepared Unit where {cols: Insertable ins + ColumnNameMap, ins: InsertRow}
```

`INSERT ... ON CONFLICT (<target>) DO NOTHING` — insert the row unless it would
collide on the target columns, in which case skip it silently. The target
callback names the conflict columns with `Db.ref` (e.g. `fun u -> [Db.ref u.email]`).

### upsert

```saga
fun upsert : Table cols -> ins -> cols -> List ColRef -> Prepared Unit where {cols: Insertable ins + ColumnNameMap, ins: InsertRow}
```

Upsert: `INSERT ... ON CONFLICT (<target>) DO UPDATE SET <rest> = EXCLUDED.<rest>`.
On a collision on the target columns, overwrite every *other* inserted column
with the value from this insert. The target callback names the conflict columns
with `Db.ref`. Panics at build time if the target covers every inserted column
(nothing left to update — use `insert_on_conflict_do_nothing`).

### insert_on_conflict_do_nothing_returning

```saga
fun insert_on_conflict_do_nothing_returning : Table cols -> ins -> cols -> List ColRef -> cols -> selection -> Prepared row where {cols: Insertable ins + ColumnNameMap, ins: InsertRow, selection: Generic selection_rep, selection_rep: Selectable row_rep, row: Generic row_rep}
```

Like `insert_on_conflict_do_nothing`, but appends a `RETURNING` clause. Note a
skipped (conflicting) row produces *no* returned row, so `Db.one` yields
`Ok Nothing` on conflict.

### upsert_returning

```saga
fun upsert_returning : Table cols -> ins -> cols -> List ColRef -> cols -> selection -> Prepared row where {cols: Insertable ins + ColumnNameMap, ins: InsertRow, selection: Generic selection_rep, selection_rep: Selectable row_rep, row: Generic row_rep}
```

Like `upsert`, but appends a `RETURNING` clause built from the projection
callback. Both the inserted and the updated row are returned, so `Db.one`
always yields the resulting row.

### upsert_set

```saga
fun upsert_set : Table cols -> ins -> cols -> ConflictTarget -> cols -> List SetExpr -> Prepared Unit where {cols: Insertable ins + ColumnNameMap, ins: InsertRow}
```

Upsert with an explicit `DO UPDATE SET`: update only the columns you list, to
arbitrary expressions over the existing row, the proposed row (`Db.excluded`),
and literals — e.g. a counter `Db.assign u.count (Db.add u.count 1)` or a merge
`Db.assign u.total (Db.add_sql u.total (Db.excluded u.total))`. The conflict
target is a `Db.ConflictTarget` (`Db.on_columns [Db.ref u.id]` or
`Db.on_constraint "…"`). For the "overwrite every other column with EXCLUDED"
default, use `upsert` instead.

### upsert_set_returning

```saga
fun upsert_set_returning : Table cols -> ins -> cols -> ConflictTarget -> cols -> List SetExpr -> cols -> selection -> Prepared row where {cols: Insertable ins + ColumnNameMap, ins: InsertRow, selection: Generic selection_rep, selection_rep: Selectable row_rep, row: Generic row_rep}
```

Like `upsert_set`, but appends a `RETURNING` clause built from the projection
callback. Yields the resulting row (inserted or updated) via `Db.one`.

### update

```saga
fun update : Table cols -> cols -> Unit needs {Update} -> Prepared Unit
```

Build an UPDATE statement. Columns are referenced through the callback's
column record; `set!`/`where_!` describe the assignments and row filter.

### update_returning

```saga
fun update_returning : Table cols -> cols -> Unit needs {Update} -> cols -> selection -> Prepared row where {selection: Generic selection_rep, selection_rep: Selectable row_rep, row: Generic row_rep}
```

Like `update`, but appends a `RETURNING` clause built from the projection
callback. Returns a `Prepared row`; run it with `Db.all` / `Db.one`.

### update_all

```saga
fun update_all : Table cols -> row -> Prepared Unit where {cols: ColumnSet + Selectable row, row: InsertRow}
```

Save a whole entity: `UPDATE <table> SET <every non-key column> WHERE <pk>`.
The entity is the domain record as-is (read → modify → save, no conversion);
the key columns come from the table's `primary_key` and form the `WHERE`, the
rest become the `SET`. The `Selectable cols row` constraint ties the accepted
entity to the table's own domain type (the same `cols -> row` link the read
path uses), so you cannot pass an unrelated record.

### delete

```saga
fun delete : Table cols -> cols -> Expr -> Prepared Unit
```

Build a DELETE statement. The predicate callback receives the table's columns.

### delete_returning

```saga
fun delete_returning : Table cols -> cols -> Expr -> cols -> selection -> Prepared row where {selection: Generic selection_rep, selection_rep: Selectable row_rep, row: Generic row_rep}
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

