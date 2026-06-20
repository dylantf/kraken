# SQL Coverage And Query Expressivity

Date: 2026-06-17

This is a working plan for the higher-level Kraken query builder. The goal is
not to implement all of SQL, but to decide which subset Kraken should own with
types, and where raw SQL remains the escape hatch.

## Update — Nullable-scope model (2026-06-18)

The library was rewritten from scratch around a new nullability model. This
section is authoritative; later sections that describe the `meta`
phantom and `Required`/`Optional` scopes (notably **Schema Ergonomics**) are
**superseded** and kept only as history. The SQL-feature tiers (predicates,
aggregates, arrays, JSONB, raw SQL) are unchanged except for the renames noted
below.

**Module layout.** Old `Kraken.Query` / `Kraken.Query.Core` are removed and
replaced by:

- `Kraken.Db` — the vocabulary (imported as `Db`): `PgType`, `Col`, `Table`,
  `Nullable`, `Array`, `Jsonb`, `Selectable`/`Projection`, typed SQL
  expressions, predicates, ordering, grouping, aggregates.
- `Kraken.Db.Query` — the `QueryBuild` effect, rendering, `Prepared`, `Repo` /
  `pg_repo`, and `all` / `one` / `run` / `into`.

**Nullability comes from exactly two places: the schema and the join kind.**

- Columns are uniform `Db.Col a` — no `meta` parameter, no `Required` /
  `Optional`. A schema-nullable column is just `Db.Col (Maybe a)`.
- `from!` / `inner_join!` return the plain column record; `left_join!` returns a
  `Db.Nullable cols` scope. Nullability of a left join lives on the *scope*, not
  on each column.

**Whole-row optional left joins now work** (previously the big open item).
Selecting a left-joined scope infers `Maybe Post` with no query-site annotation:

```saga
let u = from! users
let p = left_join! posts (fun ps -> Db.eq_col ps.author_id u.id)
select! ({ user: u, post: p })   # { user: User, post: Maybe Post }
```

This needs no compiler change and no per-table optional impl. It falls out of a
single generic instance plus an all-NULL sentinel:

```saga
impl Selectable (Maybe out) for (Nullable s) where {s: Selectable out} { ... }
# uses `nullable_row`: if every column the row spans is SQL NULL -> Nothing, else Just
```

Schema setup per table is: one domain record, one column record with
`deriving (Db.Selectable Domain)`, one `ColumnSet` impl (SQL names), and the
table value. (The `ColumnSet` impl is the remaining derive candidate, but
deriving it would need compiler support, so it stays hand-written.)

**The deliberate trade.** Per-scalar inference on a *left-joined* column was
dropped: you can no longer dot-select an individual nullable scalar
(`post_title: p.title` is not available on a left join). Instead select the whole
`Maybe Post` and reach in (`Maybe.map`). To reference a left-joined table's
columns in post-join predicates/ordering, unwrap with `Db.unwrap_cols` — the
canonical use is the anti-join `where_! (Db.is_null (Db.unwrap_cols p).id)`.
`Db.unwrap_cols` must not be used in `select!` (it would drop nullability and
fail at decode time).

## Current State

Kraken currently supports:

- typed tables and columns
- `from!`
- `inner_join!`
- `left_join!`
- repeated `where_!` clauses, rendered with `AND`
- `order_by!`
- `limit!`
- `offset!`
- anonymous-record `select!`
- selecting table scopes into domain records, such as `user: u`
- alias prefixing for nested projections, such as `user_id`
- raw predicate fragments
- raw selectable expressions through `Sql a`
- placeholder-based raw SQL with `Db.sql`, `Db.value`, `Db.raw`, and
  `Db.expr_raw`
- typed SQL value expressions with `Sql a`
- `group_by!`
- `having!`
- basic aggregate helpers: `count_star`, `count`, `count_distinct`, `sum`,
  `avg`, `min`, `max`
- query execution through `all` and `one`

Current module layout (see the Update section above):

- `Kraken.Db`
  - schema/table/column types (`Col`, `Table`, `Nullable`)
  - `PgType`
  - typed SQL expressions
  - projections and `Selectable`
  - predicates, ordering, grouping, and aggregates
- `Kraken.Db.Query`
  - `QueryBuild`
  - query collection/rendering
  - prepared queries
  - execution helpers and `pg_repo`

The demo keeps the app in `src/Main.saga` and the library modules under `lib/`.

Example:

```saga
Db.query (fun () -> {
  let u = from! users
  let p = inner_join! posts (fun post -> Db.eq_col post.author_id u.id)

  where_! (Db.eq u.name "Alice")
  where_! (Db.gt u.age 18)
  order_by! [Db.desc p.id]
  limit! 20

  select! ({ user: u, post_title: p.title })
})
```

Left joins yield a `Nullable` scope; selecting it whole infers `Maybe Post`
(see the Update section for the full model):

```saga
Db.query (fun () -> {
  let u = from! users
  let p = left_join! posts (fun post -> Db.eq_col post.author_id u.id)

  select! ({ user: u, post: p })
})
```

The inferred row shape is:

```saga
{
  user: User,
  post: Maybe Post,
}
```

(Selecting an individual nullable scalar by dotting a left-joined column — the
old `post_title: p.title` shape — is intentionally no longer supported; select
the whole `Maybe Post` instead. Whole-row optional projection, formerly a future
item, is now implemented.)

## Guiding Shape

The query builder should keep common cases compact:

```saga
select! ({ user: u, post_title: p.title })
```

and use typed helpers for common SQL constructs:

```saga
where_! (Db.gt u.age 18)
group_by! [Db.group p.author_id]
having! (Db.gt (Db.count p.id) 1)
```

Raw SQL should stay available for missing features:

```saga
where_! (Db.expr_raw "? LIKE ?" [Db.sql p.title, Db.value "Hello%"])

select! ({ total: Db.raw "COUNT(*)" [] })
```

## Tier 1: Core Select

Already present:

- `from!`
- `inner_join!`
- `left_join!`
- `where_!`
- `order_by!`
- `limit!`
- `offset!`
- `select!`

Near-term additions:

- `distinct!` (`SELECT DISTINCT` / `DISTINCT ON`) — row-level distinct; we only
  have `count_distinct` today
- `right_join!` / `full_join!` — lower priority, `left_join!` covers ~90% of
  cases; would follow the same scope/nullability model (`right_join!` makes the
  *primary* side nullable, `full_join!` makes both sides nullable)

Possible syntax:

```saga
Db.query (fun () -> {
  let p = from! posts

  group_by! [p.author_id]
  having! (Db.gt (Db.count p.id) 1)

  select! ({
    author_id: p.author_id,
    total: Db.count p.id,
  })
})
```

## Tier 2: Typed SQL Expressions

The current model now has:

- `Column meta a`
- `Sql a`
- `Expr`

Aggregates, casts, SQL functions, arithmetic, and `HAVING` all want to flow
through the shared typed SQL value expression:

```saga
Sql a
```

Current direction:

```saga
pub opaque type Sql a

pub fun raw : String -> List SqlArg -> Sql a where {a: PgType}
pub fun expr_raw : String -> List SqlArg -> Expr
```

Comparisons have moved from column-specific helpers to expression helpers via
`ToSql`:

```saga
pub fun eq : Sql a -> a -> Expr where {a: PgType}
pub fun not_eq : Sql a -> a -> Expr where {a: PgType}
pub fun gt : Sql a -> a -> Expr where {a: PgType}
pub fun eq_sql : Sql a -> Sql a -> Expr
```

Columns are still accepted directly:

```saga
Db.gt u.age 18
Db.gt (Db.count p.id) 1
```

This is modeled with:

```saga
trait ToSql input a | input -> a {
  fun to_sql : input -> Sql a
}
```

## Tier 3: Grouping And Aggregates

Implemented aggregate helpers:

- `count_star : Sql Int`
- `count : input -> Sql Int where {input: ToSql a}`
- `count_distinct : input -> Sql Int where {input: ToSql a}`
- `sum : input -> Sql (Maybe a)`
- `avg : input -> Sql (Maybe Float)`
- `min : input -> Sql (Maybe a)`
- `max : input -> Sql (Maybe a)`

Potential syntax:

```saga
Db.query (fun () -> {
  let p = from! posts

  group_by! [p.author_id]
  having! (Db.gt (Db.count p.id) 1)

  select! ({
    author_id: p.author_id,
    total: Db.count p.id,
  })
})
```

Implementation notes:

- `QueryState` has `group_bys: List Group`.
- `QueryState` has `havings: List Expr`.
- Render `GROUP BY ...` after `WHERE` and before `HAVING`.
- Render repeated `having!` clauses with `AND`, like `where_!`.
- Aggregates need to be selectable, orderable, and usable in `having!`.
- `Sql a` now carries the decoder needed for selection.

### Aggregate Nullability

SQL aggregate nullability is not determined only by whether the input column is
nullable.

`COUNT(*)`, `COUNT(expr)`, and `COUNT(DISTINCT expr)` return a non-null count.
For an empty input, the result is `0`.

Most other aggregates can return `NULL`:

- ungrouped `SUM(expr)`, `AVG(expr)`, `MIN(expr)`, and `MAX(expr)` return
  `NULL` when the query input has no rows
- aggregates over nullable expressions also return `NULL` if every input value
  for that aggregate is `NULL`
- left-joined columns are nullable at the query level, even if their underlying
  table columns are non-nullable

For grouped queries, each emitted group has at least one input row. That means
an aggregate like `SUM(non_nullable_column)` is non-null for each emitted group,
assuming no aggregate `FILTER` clause removes all rows for that aggregate. But
the type system would need to know both query cardinality shape and expression
nullability to prove that.

Conservative first signature:

```saga
count : input -> Sql Int
count_distinct : input -> Sql Int
sum : input -> Sql (Maybe a)
avg : input -> Sql (Maybe Float)
min : input -> Sql (Maybe a)
max : input -> Sql (Maybe a)
```

Potential future refinement:

```saga
sum_non_null : input -> Sql a
avg_non_null : input -> Sql Float
min_non_null : input -> Sql a
max_non_null : input -> Sql a
```

Those helpers would be an assertion or a proof-bearing API. The library should
avoid pretending it can infer non-null aggregate results until Kraken has a
clear nullability/cardinality model.

## Tier 4: Predicate Vocabulary

Implemented helpers:

- `in_`
- `not_in`
- `like`
- `ilike`
- `between`
- `eq_any`
- `not_eq_all`
- `like_any`
- `ilike_any`

Still useful later:

- `exists`
- `not_exists`
- `is_null`
- `is_not_null`

`is_null` and `is_not_null` already exist for columns. With `Sql a`, these can
be generalized:

```saga
Db.is_null p.title
Db.is_not_null p.title
Db.like p.title "Hello%"
Db.in_ u.id [1, 2, 3]
Db.eq_any u.id [1, 2, 3]
Db.like_any p.title ["Hello%", "Draft%"]
```

Empty list policy:

- `in_ x []` renders `FALSE`
- `not_in x []` renders `TRUE`
- `eq_any x []`, `like_any x []`, and `ilike_any x []` render `FALSE`
- `not_eq_all x []` renders `TRUE`

The `ANY`/`ALL` helpers currently render `ANY(ARRAY[...])` and `ALL(ARRAY[...])`
using individual bind parameters. That keeps the common predicates useful before
Kraken has a real array column/value model.

## Schema Ergonomics

> **Superseded (2026-06-18).** This section describes the old `meta` /
> `Required` / `Optional` schema model. It has been replaced by the uniform
> `Db.Col a` + `Nullable` scope model — see the **Update** section at the top.
> Kept below as history. The Array and JSONB subsections at the end remain
> accurate (modulo the `Db.Column` → `Db.Col` rename).

Current compile-time/runtime split:

```saga
record Users meta {
  id: Db.Column meta Int,
  name: Db.Column meta String,
  age: Db.Column meta Int,
}

impl Db.ColumnSet for Users meta {
  columns source = Users {
    id: Db.col "id" source,
    name: Db.col "name" source,
    age: Db.col "age" source,
  }
}

fun users : Db.Table UsersTable (Users Db.Required) (Users Db.Optional)
users = Db.table "users"
```

Compile time only tracks:

- `UsersTable`, so `from! users` can infer the right column record
- `Required` / `Optional`, so selecting a left-joined column produces `Maybe a`
- the value type `a` in `Db.Column meta a`

Runtime owns:

- table names
- table aliases
- SQL column names
- generated select aliases

Selection checkpoint:

```saga
Query.query (fun () -> {
  let foo = from! foos
  let bar = inner_join! bars (fun b -> ...)
  select! ({ foo: foo, bar: bar.name })
})
|> Query.into (fun { foo, bar } -> FoosResult { foo: foo, bar: bar })
```

`select!` is part of the query-building effect again. `Query.query` builds a
typed prepared query from the selected shape, and `Query.into` maps the prepared
query result. Using a record-pattern mapper avoids spelling the anonymous
projection type and also avoids ambiguous field lookup like `projection.user`.

Earlier demos defined both required and optional column records:

```saga
record Users source { ... Column source name a ... }
record OptionalUsers source { ... Column source name (Maybe a) ... }
```

That was only acceptable as scaffolding. The library needs an optional column
shape for outer joins, because a `LEFT JOIN` can make every column on the joined
side `NULL` even when the table column is declared `NOT NULL`. But users should
not need to define a second `OptionalFoo` record.

Target direction: derive or generic-transform the nullable mirror:

```saga
Column source name a -> Column source name (Maybe a)
```

recursively over the table column record. `from!` and `inner_join!` keep the
required shape; `left_join!` returns an optional shape.

Older schema-trait checkpoint:

```saga
pub type TableRef a = TableRef Int

pub trait TableSchema cols row insert optional_cols {
  fun schema_table_name : TableRef cols -> String
  fun schema_required_cols : String -> cols
  fun schema_optional_cols : String -> optional_cols
}

pub fun table_for : TableRef required_cols
  -> Table required_cols row insert required_cols optional_cols
  where {required_cols: TableSchema row insert optional_cols}
```

Current code has moved to a leaner table value that carries the required and
optional column-record types directly, plus a column-record-local builder:

```saga
pub trait ColumnSet cols {
  fun columns : String -> cols
}

fun users : Db.Table UsersTable (Users Db.Required) (Users Db.Optional)
users = Db.table "users"
```

That removes the separate required/optional column helper functions, the named
`OptionalFoo` record, `TableSchema`, `TableRef`, `TableScope`, and `NewFoo`
insert shapes from table setup. Column SQL names now live in the `ColumnSet`
impl for the column record itself. For 1:1 layouts, this is the piece that
should become derivable: the derive can use record field labels as SQL column
names, while custom names can keep a handwritten `ColumnSet` impl.

Tradeoff: deleting `TableScope` means exported table values need to name both
column scopes in their signature:

```saga
Db.Table UsersTable (Users Db.Required) (Users Db.Optional)
```

The previously explored `Db.Table UsersTable Users` shape would hide that, but
the current function-constraint grammar cannot express the needed
`ColumnSet (Users Db.Required)` / `ColumnSet (Users Db.Optional)` constraints
through a type-constructor parameter.
Direct optional column selection works:

```saga
let p = left_join! posts (fun post -> Db.eq_col post.author_id u.id)
select! ({ post_title: p.title })
# post_title : Maybe String
```

Whole-row projection checkpoint:

Selecting a whole required row now uses an applied derive. The user-facing
shape is:

```saga
record User {
  id: Int,
  name: String,
  age: Int,
}

record Users meta {
  id: Db.Column meta Int,
  name: Db.Column meta String,
  age: Db.Column meta Int,
} deriving (Db.Selectable User)
```

The derive specializes the generated bridge to the required table scope because
Kraken intentionally has different selected row types for required and optional
columns:

```saga
Db.Column Db.Required a -> a
Db.Column Db.Optional a -> Maybe a
```

So the generated impl is effectively:

```saga
impl Db.Selectable User for Users Db.Required
```

without also claiming that `Users Db.Optional` selects `User`.

Remaining schema ergonomics work:

- Reduce table setup further if possible. The remaining repeated shape is
  `record User`, `record Users meta`, `type UsersTable`, `ColumnSet`, and the
  `users` value. The `ColumnSet` impl is a good derive candidate when the SQL
  column names match the record fields.

- Whole-row selection from a left join is not yet implicit. Ideally:

```saga
let p = left_join! posts (fun post -> Db.eq_col post.author_id u.id)
select! ({ post: p })
# post : Maybe Post
```

Scalar optional columns work today, but a row of nullable fields is not the same
thing as `Maybe Post`. This likely needs primary-key/null sentinel metadata or a
generated bridge.

Array status:

Kraken now has an explicit `Db.Array a` wrapper:

```saga
tags: Db.Column source 'tags (Db.Array String)

Db.array ["saga", "db"]
Db.array_to_list tags
```

`Db.Array a` has `PgType` support when `a` has `PgType`, so array columns can be
selected and decoded through the normal projection path. Array values are bound
as a single parameter, rather than expanded into several placeholders.

Implemented Postgres array column predicates:

```saga
Db.contains post.tags (Db.array ["saga"])              # @>
Db.overlaps post.tags (Db.array ["db", "query"])       # &&
Db.contained_by post.tags (Db.array ["saga", "db"])    # <@
```

These helpers now work over any input with `ToArraySql`, including both array
columns and concrete `Sql (Db.Array a)` expressions:

```saga
let tags =
  Db.raw_array_like post.tags "COALESCE(?, ARRAY[]::text[])" [Db.sql post.tags]

Db.overlaps tags (Db.array ["db", "query"])
```

`Db.raw_array` exists for raw array expressions when a surrounding annotation or
use site pins the element type. `Db.raw_array_like` uses an existing array column
as the type witness, which avoids needing a local `Sql (Db.Array a)` annotation
for common raw-expression escapes.

Still open for arrays:

- Decide whether `PgType (List a)` should exist as convenience sugar or whether
  `Db.Array a` should remain the only first-class Postgres array value.
- Check runtime behavior for empty array parameters against PostgreSQL. Column
  context should usually infer the array type, but raw array expressions may need
  explicit casts.
- Add scalar membership helpers if the API wants them, for example
  `Db.any_eq post.tags "saga"` / `"saga" = ANY(tags)`.

JSONB status:

Kraken depends on `saga_json` and has a typed `Db.Jsonb a` wrapper:

```saga
record Metadata {
  source: String,
  featured: Bool,
} deriving (ToJson, FromJson)

metadata: Db.Column source 'metadata (Db.Jsonb Metadata)
```

`Db.Jsonb a` has `PgType` support when `a` has `ToJson + FromJson`.

- Encode path: `a -> SagaJson.Codec.serialize -> String -> Postgres jsonb param`
- Decode path: pgo/pg_types returns raw JSON text for `json`/`jsonb` with the
  default config, then Kraken runs `SagaJson.Codec.deserialize`
- No SQL `::text` cast is needed; direct `SELECT metadata` decodes as text under
  the current pgo config

User-facing helpers:

```saga
Db.jsonb metadata
Db.jsonb_to_value row.metadata
```

Implemented JSONB operators:

```saga
Db.json_contains post.metadata (Db.jsonb metadata)  # @>
Db.json_has_key post.metadata "featured"           # ?
Db.json_text post.metadata "source"                # ->>
```

Still open for JSONB:

- Add raw/dynamic JSON wrappers if users want to pass blobs without typed
  schema validation.
- Add more JSONB operators: JSON extraction `->`, path extraction `#>`, `#>>`,
  key-any `?|`, key-all `?&`.
- Decide whether `Json a` should mirror `Jsonb a`, or whether Kraken should only
  bless `jsonb` initially.

## Tier 5: Casts And SQL Functions

Casts are a good forcing function for `Sql a`:

```saga
Db.cast u.id Db.pg_text
```

Possible type representation:

```saga
pub opaque type PgTypeName a

pub fun pg_text : PgTypeName String
pub fun pg_int : PgTypeName Int
pub fun pg_bool : PgTypeName Bool

pub fun cast : Sql a -> PgTypeName b -> Sql b
```

Generic SQL functions can use raw fragments initially:

```saga
Db.sql_fn "lower" [Db.sql_column u.name]
```

A small typed `sql_fn` plus a handful of blessed helpers would cover most of the
expression gaps at once, instead of accreting one-off APIs:

- **`coalesce`** — especially relevant to the Nullable-scope model: it's the
  principled way to turn a left-joined `Maybe a` back into a non-null scalar
  (`COALESCE(p.count, 0)`), which the type system otherwise won't let you select
  off a left join.
- **`not_`** — general boolean negation. We have `and_` / `or_` / `is_null` /
  `is_not_null` but no negation combinator.
- **`CASE WHEN`** — conditional expressions.
- **String functions** — `lower` / `upper` / `concat` / `trim`.
- **Arithmetic** — `+` / `-` / `*` / `/` over `Sql a`, for things like
  `price * quantity`.

These all flow through `Sql a` and stay decoder-aware, so they remain selectable
and usable in `where_!` / `having!`.

## Raw SQL Escape Hatches

Kraken should prefer placeholder-based raw SQL helpers for escape hatches instead
of forcing users to assemble fragment lists by hand:

```saga
where_! (Db.expr_raw "? LIKE ?" [Db.sql p.title, Db.value "Hello%"])
select! ({ lower_name: Db.raw "LOWER(?)" [Db.sql u.name] })
```

Placeholder argument rules:

- `Db.sql value` inlines trusted typed SQL fragments, such as columns or
  computed `Sql a` expressions
- `Db.value value` creates a Postgres bind parameter
- `Db.raw` returns `Sql a`, so selection still uses the normal
  decoder path
- `Db.expr_raw` returns `Expr` for boolean predicates
- placeholder count is validated at query construction time

## Tier 6: Subqueries

A subquery is a nested `QueryBuild` handler: the builder closure runs under its own
`collect_query`, and the result is embedded into the outer query as a `SqlFrag`. The
enabler is that rendering now builds a flat `List SqlPart` and defers `$n` numbering
to one final pass (`number_parts`) — so a subquery's params are numbered *in
sequence by the outer query*, no renumbering or placeholder rewriting. Aliases are
namespaced by a per-scope prefix in `QueryState` (`t` outer, `s` subquery) so a
correlated subquery never collides with the outer scope.

Status:

- **`EXISTS` / `NOT EXISTS`** (done) — `Query.exists` / `Query.not_exists` take a
  builder closure and return an `Expr` for `where_!`. Renders `EXISTS (SELECT 1 …)`;
  reference outer columns directly inside for correlation.
- **Derived table / subquery in `FROM`** (done) — `Query.from_subquery` runs the
  closure, turns its `select!` labels into a column scope (the `DerivedScope` generic
  walk rewrites `Sql a`/`Col a` → `Col a`, named by label, sourced at the derived
  alias), and binds it as the FROM source. The outer query dots into it
  (`t.posts`, `is_null t.id`) with full inference — no annotation (this is what the
  compiler's `rep -> type` inference fix on 2026-06-20 unblocked).
- **`IN (subquery)` / `NOT IN (subquery)`** (done) — `Query.in_subquery` /
  `not_in_subquery`. The subquery closure *returns* the single column to match
  (no `select!`), and both the left input and that column are `ToSql a`, so their
  element types must agree (`id IN (subquery of names)` won't compile). Renders
  `<left> IN (SELECT <col> FROM …)`. (Literal-list `in_` still exists for the
  in-memory case.)
- **scalar subquery as `Sql a`** (todo) — the same "closure returns the column"
  pattern, but wrapping the rendered `SELECT` as a `Sql a` (with the column's
  decoder) so it can be used in `select!` / comparisons; needs single-row semantics.
- **CTEs (`WITH`)** (todo).

Design decisions:

- **One FROM per query, enforced.** `from!` / `from_subquery` set a single
  `from_source`; a second one now panics with a clear message (it used to silently
  clobber the first). Add more tables with `inner_join!` / `left_join!`.
- **No comma joins.** `FROM a, b` (old-style cross join filtered in `WHERE`) is
  strictly redundant with the explicit `inner_join!` / `left_join!` we already have,
  so it is deliberately not supported.
- **Alias nesting is one level deep.** Sibling subqueries are fine (each `s0` lives
  in its own parenthesized SQL scope), but a *correlated subquery nested inside
  another subquery* reuses the `s` prefix and would be ambiguous. Fixing it means
  threading a monotonic alias counter through the effect rather than a fixed `t`/`s`
  prefix — deferred until a real need appears.

## Tier 7: DML

**Priority: highest. Kraken is read-only today — this is the structural gap.**

### Implementation status (2026-06-19)

Built and compiling in `Kraken.Db.Dml`: **`insert`** (Rung 1), **`update`**,
**`delete`**, and **`exec`** (non-returning, returns affected-row count via
`Returned.count`). Demonstrated in `src/Write.saga`. Schema column records
(`Users`/`Posts`) are now `pub` in `src/Read.saga` so the write side can reference
their columns; a shared `Schema` module is the next cleanup.

Rendered SQL (verified by tracing):

```
INSERT INTO users (name, age) VALUES ($1, $2)              -- ["Carol", 31]
UPDATE users SET age = $1 WHERE users.id = $2              -- [43, 1]   (set!)
UPDATE users SET name = $1, age = $2 WHERE id = $3         -- ["Alice Updated", 31, 1]  (update_all)
DELETE FROM users WHERE users.id = $1                      -- [999]
```

**`update_all` (whole-entity save) + `primary_key`** (done 2026-06-19): takes the
domain record as-is, encodes it via `InsertRow`, and partitions the columns by the
table's primary key — key columns form the `WHERE`, the rest the `SET`. The key is
declared on the per-table `ColumnSet` impl:

```saga
impl Db.ColumnSet for Users {
  columns source = Users { id: Db.generated "id" source, ... }
  primary_key u = Db.key u.id          -- key : c -> PrimaryKey where {c: AsColRef}
}
```

`primary_key : cols -> PrimaryKey` has a **default of `NoKey`**, so tables you
never `update_all` skip it. `PrimaryKey = NoKey | Key ColRef | Composite (List
ColRef)`; `key`/`ref`/`composite` build it, and `AsColRef` is implemented for both
`Col` and `Generated` so a serial PK (`u.id : Generated Int`) works. `update_all`
on a `NoKey` table panics with a clear message.

**Insert takes a dedicated, named insert type** (`record NewUser { name, age }
deriving (Db.InsertRow)`), not the domain record and not an anonymous record:

- `insert : Table cols -> input -> Prepared Unit where {input: InsertRow}`.
- Type safety comes from the named type itself — `NewUser { name: 31 }` fails
  ("expected String, got Int"), and an anonymous record is rejected outright
  ("no impl of InsertRow for anonymous record type"). So you can't fat-finger a
  column type or pass an ad-hoc shape.
- You declare the columns you set and omit the rest (DB-generated columns, or
  any with a default). To *force* a normally-generated column (e.g. a specific
  `created_at`), just include it in your insert type — insert never consults the
  schema, so it inserts whatever columns the type carries.

**Kraken does not cross-validate the insert type against the schema** (that
`{name: 31}` started this discussion was a red herring — it only typechecked
because insert briefly accepted anonymous records). Checking that an *input DTO*
is well-formed is a separate concern (an input-validation library in the
`input |> validate |> insert` pipeline), explicitly out of scope here. The
`validate` step constructs the named insert type; `insert` consumes it.

**`Generated a` marker** (added 2026-06-19): schema columns that the DB fills
(`id : Db.Generated Int`). It reads and behaves exactly like `Col a` in
selects/predicates/joins (mirror `Selectable`/`ToSql` instances), and because
`set`/`value` only accept `Col a`, it also makes generated columns
**unsettable** in `set!` (can't accidentally update a PK).

**How insert encoding was solved (and why not a mirror derive).** `Insertable`
cannot be the contravariant write-mirror of `Selectable` via the routed
functional-bridge derive: `derive_applied_functional_bridge` only ever emits a
*covariant* bridge (`map from` over the wrapper), which suits `Projection`
(produces the row) but not an encoder (consumes the row). Instead, insert encoding
is a **covariant fold over the domain record's Generic representation**, exactly
mirroring saga_json's `ToJson` / `ToJsonFields` split:

- `InsertRow a` — single-param, **derivable** (`deriving (Db.InsertRow)` on the
  domain record). The bare derive generates a concrete `impl InsertRow for User`
  that delegates through `to` to the rep instances (where the rep type expands).
- `InsertFields` (internal) walks `And` / `Labeled`; `EncodeLeaf` encodes each
  `Leaf` value via `PgType`. The `Labeled n` node carries the field label, which
  becomes the column name (Rung 1: column name = field name).

A generic `row_columns_values : row -> … where {row: Generic rep, rep: …}` did
*not* work — at the call site `rep` unified to the nominal `Rep__User`, which has
no structural instance. Routing through a derived single-param trait (like
`ToJson`) is the pattern that resolves, because the generated concrete impl is
where the rep expands.

The builder is a uniform `!`-effect-operation DSL — `set!` / `where_!` inside the
`update` closure:

```saga
Dml.update users (fun u -> {
  set! u.age 43
  where_! (Db.eq u.id 1)
})
```

This briefly hit a wall: an effect operation's `where` constraints did not reach
its handler, so a handler for `set : Col a -> a -> Unit where {a: PgType}` could
not call `encode_value` (no `PgType a` in scope). That was **fixed in the compiler
on 2026-06-19** — operation constraints now deliver their evidence to the handler
— so `set!`/`where_!` work as effect ops and DML stays consistent with the read
DSL. (Two parser quirks remembered along the way: `(List.append …)` fails to parse
because `List` is also a type, so a parenthesized `List.append` reads as a
qualified type; and multi-line function application with args on following lines
leaves the function unapplied. Both are avoided by binding intermediate `let`s.)

**`update_all` schema-tied** (done 2026-06-19): the accepted entity type is now
pinned to the table via the read path's own `Selectable cols row | cols -> row`
link (`where {cols: ColumnSet + Selectable row, row: InsertRow}`), so passing an
unrelated record is a compile error (`no impl of Selectable for <Table>`). No new
trait — it reuses the same `cols -> row` fundep that `select`/`all` rely on.

**`RETURNING`** (done 2026-06-19): `insert_returning` / `update_returning` /
`delete_returning` take a projection callback over the table's columns (exactly
like `select!`) and return a `Prepared row`, runnable with `Query.all` /
`Query.one`. Implemented by reusing `Db.select` to build the `Projection`,
rendering its selection frags as the RETURNING list (positional decode, so aliases
are dropped), and setting `Prepared.decode = decode_projection`. E.g.
`INSERT INTO users (name, age) VALUES ($1, $2) RETURNING users.id` decoded into
`{ id: Int }`, or `(fun u -> u)` to get the whole row back as the domain type.

**`ON CONFLICT` upsert** (done 2026-06-19): two type-safe entry points, conflict
targets named with `Db.ref` (not raw strings):
- `insert_on_conflict_do_nothing table row (fun u -> [Db.ref u.email])` →
  `INSERT … ON CONFLICT (email) DO NOTHING`.
- `upsert table row (fun u -> [Db.ref u.id])` →
  `INSERT … ON CONFLICT (id) DO UPDATE SET <every other inserted col> = EXCLUDED.<col>`
  — the standard "insert or overwrite with my new values" upsert. Panics at build
  time if the target covers every inserted column (nothing left to update).

`ON CONFLICT` + `RETURNING` (done 2026-06-19): `upsert_returning` and
`insert_on_conflict_do_nothing_returning` mirror the plain returning ops (a skipped
DO-NOTHING row returns nothing, so `Query.one` gives `Ok Nothing` on conflict).

Tier 7 is complete. Not yet built (smaller follow-ups): `DO UPDATE` to a chosen
*subset* of columns or to arbitrary expressions (e.g. `count = users.count + 1`);
`ON CONSTRAINT <name>` conflict targets. (Transactions — Tier 8 — are now done,
built as a thin wrapper over saga_pgo's `Transaction` effect.)

Inference note worth remembering: a DML op taking *two* column-record callbacks
(e.g. `*_returning` conflict ops: a conflict-target `(cols -> List ColRef)` and a
projection `(cols -> selection)`) can fail to pin `cols` early enough, so a bare
`u.field` in the target lambda reports "ambiguous field" when `field` also exists
on the domain/insert records in scope. A whole-row projection (`fun u -> u`) pins
`cols` strongly enough for both lambdas; an anonymous projection (`fun u -> { … }`)
may not. Annotating the lambda doesn't help (param annotations don't parse, and a
typed `let` flows too late for field disambiguation). Workaround: use a whole-row
projection, or reference the column from a scope where `cols` is already fixed.

### Worked design

This section is the worked-out DML design (2026-06-18). New module
`Kraken.Db.Dml` (imported as `Dml`), parallel to `Kraken.Db.Query`, reusing the
existing `Db` vocabulary: `Table` / `Col` / the `Schema` trait, `PgType.encode_pg`
for value encoding, `Selectable`/`Projection` for `RETURNING`, and
`Prepared`/`Repo`/`all`/`one` for execution.

### Guiding principle: two axes of schema config

Configuration about a table splits cleanly by *what it affects*, and that
decides where it lives:

- **Type-level config = *shape*** (which columns exist, which are insertable).
  Must live in the record field types, because it changes types the derive sees.
  This is the `Col a` vs `Generated a` split below.
- **Value-level config = *behavior*** (primary key, future hooks, table-name
  overrides, soft-delete scope). Lives in the `Schema` trait impl, because it
  never reshapes a type — it only changes rendering. Runtime is the right home.

This is the principled version of Drizzle's column config object. Saga has no
field attributes (`@generated(...)`), and a fully type-level config object would
explode combinatorially (`Col` / `Generated` / `Pk` / `GeneratedPk` / …), which
is exactly why Drizzle uses a runtime dict there — so we put only the one thing
that genuinely must be type-level (insert input shape) in the field type, and
everything else in the value-level impl.

### Column shape: `Col a` vs `Generated a`

```saga
record Users {
  id: Db.Generated Int,     # DB supplies it (SERIAL / identity / default)
  name: Db.Col String,
  age: Db.Col Int,
} deriving (Db.Selectable User, Db.Insertable User)
```

- `Db.Col a` — an app-provided column.
- `Db.Generated a` — a DB-managed column. Omitted from insert input (you can't
  pass it) and excluded from update `SET` (the app never writes it). The type
  marker is what lets the `Insertable` derive drop the field from the *input
  shape*; a runtime flag couldn't, because the derive only sees types.
- `Generated a` must still behave like a column in reads/predicates/joins, so it
  needs the same mirror instances as `Col a` (`Selectable a for Generated a`,
  `ToSql a for Generated a`, …) delegating to the `Col` versions. Small,
  mechanical.

This extends the library's north star — nullability already comes from "schema +
join kind"; now **insertability comes from the schema too** (`Col` = you provide
it, `Generated` = the DB does).

### Value-level config: the `Schema` trait

Saga has default trait methods, so `columns` is required and everything else
defaults — a table overrides only what it uses (no per-table boilerplate for
features it doesn't need):

```saga
pub trait Schema cols row {
  fun columns : String -> cols
  fun primary_key : cols -> PrimaryKey   # default: NoKey
  # future: pure transform hooks (before_save, after_load), table-name override
}

impl Db.Schema Users User {
  columns src = Users { id: Db.col "id" src, name: Db.col "name" src, age: Db.col "age" src }
  primary_key u = Db.key u.id            # static: just points at the key column
}
```

`primary_key` is pure projection — it *names* the key column(s); it does not
build a predicate. Assembling `id = $1` is the query layer's job (`update_all` /
entity-delete take the column name from `primary_key cols`, pull the matching
value out of the entity, and build the `WHERE`). The config stays declarative.

### Primary keys: `PrimaryKey` / `ColRef`

Composite-key columns differ in type (`org_id: Col Int`, `user_id: Col String`),
so a composite key can't be `List (Col a)` — the list must hold **erased** column
refs:

```saga
pub type PrimaryKey =
  | NoKey                       # default — table declared none
  | Key ColRef                  # single (the 95% case)
  | Composite (List ColRef)     # multi-column

# ColRef is the erased column (drop the phantom). Col a is already
# `Col ColumnInfo` internally, so ColRef just exposes that ColumnInfo
# (name + source) — exactly what the WHERE builder needs.
pub fun key : Col a -> PrimaryKey         # -> Key (erases internally)
pub fun ref : Col a -> ColRef             # for composite lists
pub fun composite : List ColRef -> PrimaryKey
```

```saga
primary_key u = Db.key u.id                                   # single
primary_key u = Db.composite [Db.ref u.org_id, Db.ref u.user_id]   # composite
```

The single/composite split is **purely call-site ergonomics** — `Key` is sugar
for a one-element `Composite`. Consumers normalize to a list immediately and
treat both identically: an `AND` of `col = value`, one term per key column.
**Ship single-key first**; composite is a later generalization.

### Surface

Three distinct write operations, chosen so the read→mutate→save round-trip never
needs a shape conversion:

```saga
# INSERT — record literal, no `set!` spam. Generated cols omitted & type-enforced.
Dml.insert users { name: "Alice", age: 42 }

# INSERT ... RETURNING — closure ends in a selection, exactly like select!
Dml.insert_returning users { name: "Alice", age: 42 } (fun u -> { id: u.id })

# UPDATE (targeted/partial) — only write what changes. `set`/`where_` are plain
# functions returning clauses (see Implementation status for why not `!`-ops).
Dml.update users (fun u -> [
  Dml.set u.age 43,
  Dml.where_ (Db.eq u.id 1),
])

# UPDATE (save whole entity) — eats the domain record as-is, keyed by primary_key.
let updated = { user | age: 43 }       # native record update; no UserUpdate type
Dml.update_all users updated           # UPDATE users SET name=$1, age=$2 WHERE id=$3

# DELETE
Dml.delete users (fun u -> { where_! (Db.eq u.id 1) })
```

Notably **there is no id-less, Maybe-wrapped `UserUpdate` mirror record** — that
shape is exactly what would force a `User -> UserUpdate` conversion on every
fetch→mutate→save. `set!` covers targeted partials and `update_all` covers the
entity flow, so the patch record earns its place nowhere and is omitted.

### Insert input

`Db.Insertable` is the write-direction mirror of `Db.Selectable`: where
`Selectable` walks the Generic rep to build a decoder (`Col a` → read `a`),
`Insertable` walks it to build `[(column_name, Value)]` (`a` → `encode_pg`), and
**drops `Generated` fields** so the accepted input is the column set minus
DB-managed columns. This is genuinely more than `Selectable`'s 1:1 walk (it must
match the input record against a *subset* of the schema columns), so it's the
main piece of new derive work to validate.

Staging ladder (stop where cost/benefit feels right):

- **Rung 1 (no subset derive):** `Insertable` over the *full* domain record — you
  supply every column including the key. Mirrors `Selectable` exactly, ships
  fastest, fine for app-side UUID PKs. Add `Generated` to the schema from the
  start regardless (cheap, right source of truth).
- **Rung 2 (target):** subset-aware `Insertable` that drops `Generated` → the
  `{ name, age }` literal with the key omitted and type-enforced. Validate that
  the derive machinery can drop fields before committing the surface.

### Execution / implementation notes

- **`RETURNING`** reuses the `Selectable`/`Projection` decode path, so a returning
  write produces a `Prepared row` and executes through `all`/`one` exactly like a
  read. Non-returning writes produce a command that yields rows-affected.
- **Encoding exposes all columns including generated.** The row-encoding step
  pairs every column with its value; the *operations* filter: `insert` drops
  `Generated`; `update_all`'s `SET` drops `Generated` + key columns; the `WHERE`
  uses the key columns. (So `update_all` can still read the key's value off the
  entity even when the key is `Generated`/serial.) The type-level `Generated`
  marker drives a runtime tag on each encoded column so the operations can do
  this filtering.
- **`ON CONFLICT` upsert**: target columns/constraint + `DO NOTHING` / `DO UPDATE
  SET ...`. Design alongside the first cut, or as the immediate follow-up.

### Open / deferred

- Composite keys: ship single-key first.
- Transform hooks (`before_save`, `after_load`): powerful but *implicit magic*
  (silent rewrites, ordering, testability, effectful hooks dragging `needs {…}`
  onto the write path). Many use cases (auto `created_at`) are better served by a
  DB `DEFAULT now()` + `Generated`. If added, keep them **pure** and opt-in, and
  do it *after* the core DML — not baked in now.
- The subset-aware `Insertable` derive (Rung 2) needs compiler-side validation.

## Tier 8: Transactions

**Done (2026-06-19).** `Query.transaction conn body` runs a closure atomically,
committing on `Ok` and rolling back on `Err`. It's a thin wrapper over
`SagaPgo.transaction` — **no direct Erlang/pgo bridging** (per the saga_pgo
transaction guide, the library already drives the BEGIN/COMMIT/ROLLBACK lifecycle
and routes every `Postgres` op on the same connection into the transaction via
pgo's process dictionary).

Final shape:

```saga
pub fun transaction : Connection
  -> (Unit -> Result a DbError needs {Repo})
  -> Result a DbError
  needs {Postgres, Transaction}

Query.transaction conn (fun () -> {
  case Dml.exec conn (Dml.insert users new_row) {
    Err err -> Err err                       # rolls back
    Ok _ -> Dml.exec conn (bump_age_query ()) |> Result.map (fun _ -> ())
  }
  # commits on Ok, rolls back on Err
})
```

Resolved design decisions:

- **Not its own effect.** `transaction` is a plain function over saga_pgo's
  `Postgres` + `Transaction` effects. It provides `pg_repo` *inside* the body, so
  the body uses the ordinary Kraken `Repo` API (`all`/`one`/`exec`/the DML
  helpers) and those calls auto-join the transaction. The boundary therefore needs
  `{Postgres, Transaction}` (wire `with {pg_transaction, pg, ...}` — dependent
  handler first), not `Repo`.
- **Error-channel impedance.** saga_pgo's callback rolls back via a
  `QueryError`-typed `Err`, but Kraken bodies fail with `DbError`. A `QueryFailed`
  round-trips losslessly; a `DecodeFailed` (a row returned but undecodable) rolls
  back with its message preserved (mapped onto `UnexpectedResultType`). This is the
  one lossy corner and it's documented.
- **Continuation caveat (inherited from saga_pgo):** don't let a continuation
  captured inside the body escape and run later — its re-invocation happens after
  commit/rollback, outside the transaction.

Still open (later refinements): savepoints / nested transactions, isolation-level
configuration.

## Open Design Questions

### Should `Sql a` Replace `SelectExpr a`?

Decision: yes.

`Sql a` now carries the fragment and decoder needed for selection, so
`SelectExpr a` is redundant. Aliasing should come from anonymous record labels:

```saga
select! ({ total: Db.count_star })
select! ({ lower_name: Db.raw "LOWER(?)" [Db.sql u.name] })
```

The default alias for selecting a bare `Sql a` is still `value`, but the preferred
surface API is to put raw or computed expressions behind record labels.

### How Should Whole-Row Optional Left Joins Work?

**Resolved (2026-06-18).** `left_join!` returns a `Db.Nullable cols` scope, and a
single generic instance `Selectable (Maybe out) for (Nullable s)` lifts any
selectable scope to its `Maybe` form, using an all-NULL sentinel (`nullable_row`)
to decide `Just` vs `Nothing`:

```saga
let p = left_join! posts (fun ps -> Db.eq_col ps.author_id u.id)
select! ({ user: u, post: p })   # { user: User, post: Maybe Post }
```

No compiler change and no per-table impl. The trade was dropping per-scalar
inference on left-joined columns (select the whole `Maybe Post` instead). See the
**Update** section at the top for the full design and rationale.

### Should Query Result Types Be Named At Public Boundaries?

Anonymous records infer nicely inside a module, but exported functions need
signatures. Public APIs should probably prefer named records:

```saga
pub record UserPost {
  user: User,
  post_title: String,
}

pub fun user_posts_query : Unit -> Db.Prepared UserPost
```

Anonymous projections remain ideal for local query construction.

## Suggested Next Step

### Prioritized roadmap (2026-06-18)

The read path is well-rounded; the headline gap is that **Kraken is read-only**.
Priority order:

**Tier 1 — structural (do first).** Without these you can't build a real app on
Kraken.

- **DML**: `insert!` / `update!` / `delete!` with `RETURNING` (reuses the
  `Selectable`/`Projection` decode path) and `ON CONFLICT` upsert. See
  [Tier 7: DML](#tier-7-dml). This is also the next stress test of the schema
  representation — writes type-check the column record from the *write*
  direction, which is where the `ColumnSet` duplication will bite again.
- **Transactions** *(done 2026-06-19)*: `Query.transaction conn body` runs a
  closure atomically (commit on `Ok`, rollback on `Err`), wrapping
  `SagaPgo.transaction`. See [Tier 8: Transactions](#tier-8-transactions).

**Tier 2 — read expressivity.**

- **Subqueries**: `EXISTS` / `IN (subquery)` / scalar subqueries / CTEs
  (`WITH`). `in_` currently only takes a literal list; correlated subqueries are
  the most common next reach. See [Tier 6: Subqueries](#tier-6-subqueries).
- **`SELECT DISTINCT` / `DISTINCT ON`** (`distinct!`). Row-level distinct; we
  only have `count_distinct` today.
- **Expression functions**: `coalesce` (the principled way to recover a non-null
  scalar from a left join, given the Nullable-scope model), `lower`/`upper`,
  arithmetic, `concat`, `CASE WHEN`, and a generic `not_`. A small `sql_fn`/
  expression builder covers most of these at once rather than one-off helpers.
  See [Tier 5: Casts And SQL Functions](#tier-5-casts-and-sql-functions).
- **Casts** through `PgTypeName a`.

**Tier 3 — polish.**

- `right_join!` / `full_join!` (left covers ~90% of cases).
- Window functions.
- An exactly-one query variant alongside `one` (which returns `Maybe`) that
  errors on 0 or >1 rows.
- Make the `ColumnSet` impl derivable (field label → SQL column name) — the last
  piece of per-table boilerplate; needs compiler-side derive support.

Done since this plan was written: `SelectExpr` removed in favor of `Sql a`;
aggregate nullability for `sum`/`avg`/`min`/`max`; the `like`/`ilike`/`between`/
`in_` predicate family; and whole-row optional left join projection
(`post: Maybe Post`) via the Nullable-scope model.

This continues growing the SQL surface on top of the typed expression model
instead of adding one-off APIs.
