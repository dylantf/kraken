---
title: Kraken.Query
---

## Types

### Prepared

```saga
record Prepared a {
  sql: String,
  params: List Value,
  decode: RelData -> Dynamic -> Result (a, List RelSlot) DecodeError,
  relations: List RelSpec,
  noop: Bool
}
```

A compiled query: rendered SQL, its bound parameters, and a decoder that turns
one result row into an `a`. Produced by `query` and consumed by `all`/`one`.

`noop` marks a statement that affects and returns no rows without a database
round trip — built for empty bulk operations (e.g. `Db.insert_all` on `[]`),
where there is no valid SQL to send. `all` short-circuits to `Ok []`, `exec` to
`Ok 0`; everything else carries `noop: False`.

### DbError

```saga
type DbError =
  | QueryFailed QueryError
  | DecodeFailed DecodeError
  | ExpectedOneRow Int
  deriving (Debug)
```

Why running a query failed: the database rejected it (`QueryFailed`) or a
returned row did not match the expected shape (`DecodeFailed`).

### Select

```saga
opaque type Select a
```

The result shape of a query builder: the value passed to `select` wrapped so a
builder closure's *return* is required to be a projection. `Select` is opaque, so
`select` is the only way to produce one — a query body therefore cannot forget to
select, return a bare record, or have an early selection silently shadowed.

### Relation

```saga
opaque type Relation pcols ccols child k
```

A to-many relation: a parent column matched to a child column. Build with
`has_many`, consume with `preload` → `List child` (or `preload_where` to scope the
loaded children). Both accessors are *column* accessors (over the parent's and
child's column records `pcols` / `ccols`), so the foreign key is named exactly once
and the batched child query (`WHERE child_key IN (keys)`) is generated for you.

authored_posts = Db.has_many posts (fun u -> u.id) (fun p -> p.author_id)

### RelationOne

```saga
opaque type RelationOne pcols ccols child k
```

A to-one relation: the same join as `Relation`, built with `belongs_to` (the FK is
on the parent) or `has_one` (the FK is on the child, ≤1 per parent), and consumed
with `preload` → `Maybe child`. A distinct type so the to-one result shape follows
the relation automatically (and a to-many can't be mis-consumed as one).

## Traits

### Preloadable

```saga
trait Preloadable rel pcols ccols out | rel -> pcols ccols out {
  fun run_preload : rel -> pcols -> Maybe (ccols -> Expr) -> Preloaded out needs {QueryBuild}
}
```

## Effects

### Repo

```saga
effect Repo {
  fun execute : Connection -> Prepared a -> Result (Returned Dynamic) QueryError
}
```

The capability to execute a prepared query against a connection. Provide a
handler (such as `pg_repo`) at the call boundary; tests can supply their own.

### QueryBuild

```saga
effect QueryBuild {
  fun from : Table cols -> cols
  fun bind_derived : DerivedTable scope -> scope
  fun define_cte : DerivedCte scope -> Table scope
  fun inner_join : Table cols -> cols -> Expr -> cols
  fun left_join : Table cols -> cols -> Expr -> Nullable cols
  fun distinct : Unit -> Unit
  fun distinct_on : List Group -> Unit
  fun where_ : Expr -> Unit
  fun group_by : List Group -> Unit
  fun having : Expr -> Unit
  fun order_by : List Order -> Unit
  fun limit : Int -> Unit
  fun offset : Int -> Unit
  fun peek_aliases : Unit -> Int
  fun commit_aliases : Int -> Unit
  fun relation_count : Unit -> Int
  fun push_relation : RelSpec -> Unit
}
```

The query-building DSL. Its operations are performed with `!` inside the
closure passed to `query`, in the order a SELECT reads.

## Handlers

### pg_repo

```saga
handler pg_repo for Repo needs {Postgres}
```

The production `Repo` handler: runs each query against PostgreSQL via `Postgres`.

## Functions

### noop_prepared

```saga
fun noop_prepared : Prepared a
```

A no-op prepared statement: executing it touches no rows and returns none,
without hitting the database. Polymorphic in the row type, so it serves both
`Prepared Unit` (non-returning) and `Prepared row` (returning) empty batches.
Its `decode` is never invoked (there are no rows), so it just reports an error.

### select

```saga
fun select : a -> Select a
```

Name a query's result shape. The `!` verbs (`from!`, `where_!`, …) build the
query; `select` names what comes back, and its value's type determines the row
type `all`/`one` decode. It is the closing expression of a `query` /
`from_subquery` / `cte` / full-join body — pure, not an effect.

### query

```saga
fun query : Unit -> Select selection needs {QueryBuild} -> Prepared row where {selection: Generic selection_rep, selection_rep: Selectable row_rep, row: Generic row_rep}
```

Build a `Prepared` query from a builder closure. The closure performs
`QueryBuild` operations (`from!`, `inner_join!`, …) and *returns* a `select (…)`;
the type selected determines the row type that `all`/`one` will decode.

### full_join_query

```saga
fun full_join_query : Table colsA -> Table colsB -> colsA -> colsB -> Expr -> (Nullable colsA, Nullable colsB) -> Select selection needs {QueryBuild} -> Prepared row where {selection: Generic selection_rep, selection_rep: Selectable row_rep, row: Generic row_rep}
```

Build a FULL OUTER JOIN query between two tables. A full join is symmetric (no
"primary" table), so it's its own constructor rather than a chained join: it takes
both tables, the join `ON` (over their plain columns), and a body that receives
both as `Nullable` scopes — because either side can be absent. Selecting those
scopes therefore yields `Maybe row` on both, which is the honest type for a full
join (a row can be left-only, right-only, or matched).

This is sound by construction: the body never gets a non-null binder for these
tables, so there's no way to bind one non-null and have the full join silently
NULL it. The body is the ordinary `QueryBuild` DSL (add `where_!`, `order_by!`,
etc., then `select`); `from!` would panic (the FROM is already set). Reference a
scope's columns in further predicates via `Db.unwrap_cols`.

full_join_query employees departments
(fun e d -> Db.eq_col e.dept_id d.id)
(fun emp dept -> { select ({ employee: emp, department: dept }) })

### from_subquery

```saga
fun from_subquery : Unit -> Select selection needs {QueryBuild} -> scope needs {QueryBuild} where {selection: Generic sel_rep, sel_rep: Selectable row_rep + DerivedScope scope_rep, scope: Generic scope_rep}
```

Use a subquery as a derived table in `FROM`. The builder closure is the same
`from!`/`where_!`/`select` DSL under a nested handler; each `select` label
becomes a column of the derived table, returned as a scope you dot into in the
outer query:

let t = from_subquery (fun () -> {
let p = from! posts
group_by! [Db.group p.author_id]
select ({ author_id: p.author_id, posts: Db.count_star })
})
where_! (Db.gt t.posts 5)
select ({ author: t.author_id, posts: t.posts })

The subquery's params are numbered in sequence by the outer query, and its own
tables get an `s`-prefixed alias so they never clash with the outer `t`-aliases.

### cte

```saga
fun cte : String -> Unit -> Select selection needs {QueryBuild} -> Table scope needs {QueryBuild} where {selection: Generic sel_rep, sel_rep: Selectable row_rep + DerivedScope scope_rep, scope: Generic scope_rep}
```

Define a named CTE and get back a `Table` handle for it. The builder closure is
the same `from!`/`select` DSL as `from_subquery`; each `select` label becomes a
column of the CTE. Unlike `from_subquery`, the body is hoisted into a leading
`WITH <name> AS (…)` and the handle is referenced by name — so it can be used in
several places (e.g. `from!` it and also `inner_join!` it):

let counts = cte "post_counts" (fun () -> {
let p = from! posts
group_by! [Db.group p.author_id]
select ({ author_id: p.author_id, posts: Db.count_star })
})
let c = from! counts
where_! (Db.gt c.posts 5)
select ({ author: c.author_id, posts: c.posts })

Renders `WITH post_counts AS (…) SELECT … FROM post_counts AS t0 WHERE …`. The
CTE's params are numbered in sequence (the `WITH` is rendered first), and its own
tables get an `s`-prefixed alias so they never clash with the outer `t`-aliases.

### into

```saga
fun into : row -> out -> Prepared row -> Prepared out
```

Map a prepared query's decoded rows through `transform`. The SQL and parameters
are unchanged; only the decoded result type changes. Useful for turning an
anonymous projection record into a named domain type.

### number_parts

```saga
fun number_parts : List SqlPart -> (String, List Value)
```

### exists

```saga
fun exists : Unit -> a needs {QueryBuild} -> Expr needs {QueryBuild}
```

A correlated `EXISTS (…)` subquery predicate. The builder closure uses the same
`from!` / `where_!` / … DSL; reference an outer table's columns directly inside it
for correlation (their aliases are captured at bind time). Subquery tables get an
`s`-prefixed alias, and alias numbering continues from the enclosing scope's
counter, so even a correlated subquery nested inside another never reuses (and
shadows) an enclosing alias.

where_! (Db.exists (fun () -> {
let p = from! posts
where_! (Db.eq_col p.author_id u.id)
}))

### not_exists

```saga
fun not_exists : Unit -> a needs {QueryBuild} -> Expr needs {QueryBuild}
```

The negation of `exists`: `NOT EXISTS (…)`.

### in_subquery

```saga
fun in_subquery : input -> Unit -> col needs {QueryBuild} -> Expr needs {QueryBuild} where {input: ToSql a, col: ToSql a}
```

`<input> IN (subquery)`. The subquery closure ends by *returning* the single
column to select (not via `select`); its element type must match `input`'s:

where_! (Db.in_subquery u.id (fun () -> {
let p = from! posts
where_! (Db.eq p.published True)
p.author_id
}))

### not_in_subquery

```saga
fun not_in_subquery : input -> Unit -> col needs {QueryBuild} -> Expr needs {QueryBuild} where {input: ToSql a, col: ToSql a}
```

The negation of `in_subquery`: `<input> NOT IN (subquery)`.

### scalar_subquery

```saga
fun scalar_subquery : Unit -> col needs {QueryBuild} -> Core.Sql a needs {QueryBuild} where {col: ToSql a, a: Core.PgType}
```

A scalar subquery used as a value: `(SELECT <col> FROM …)` wrapped as a `Sql a`,
so it's selectable and usable in comparisons (`Db.gt_sql u.age (scalar_subquery
…)`, `Db.eq_sql …`). The closure *returns* the single column (like `in_subquery`,
no `select`).

This variant types the result as non-null `Sql a`, so it is sound only when the
subquery is *guaranteed* to return exactly one row with a non-null value — an
ungrouped aggregate (`COUNT(*)` is always one row), or a lookup you've constrained
to one present row. If the subquery can match zero rows, the result is SQL NULL and
decoding fails at runtime; use `scalar_subquery_maybe` (which types that as
`Maybe a`) or wrap the call site in `Db.coalesce`.

### scalar_subquery_maybe

```saga
fun scalar_subquery_maybe : Unit -> col needs {QueryBuild} -> Core.Sql (Maybe a) needs {QueryBuild} where {col: ToSql a, a: Core.PgType}
```

Like `scalar_subquery`, but types the result as `Sql (Maybe a)` — the honest type
when the subquery can return zero rows (an empty result decodes to `Nothing`
instead of failing). This is the safe default; reach for `scalar_subquery` only
when the subquery provably yields one non-null row.

select ({
id: u.id,
a_title: Db.scalar_subquery_maybe (fun () -> {
let p = from! posts
where_! (Db.eq_col p.author_id u.id)
limit! 1
p.title
}),
})   # { id: Int, a_title: Maybe String }

### run

```saga
fun run : Connection -> Prepared a -> Result (Returned Dynamic) QueryError needs {Postgres}
```

Execute a prepared query and return the raw, undecoded rows. Low-level: most
callers want `all` or `one`, which decode through the `Repo` effect.

### all

```saga
fun all : Connection -> Prepared a -> Result (List a) DbError needs {Repo}
```

Execute a prepared query and decode every row into an `a`. Returns `DbError` if
the query fails or any row fails to decode.

When the query has `preload`ed relations, decoding runs in two passes: the first
decodes one row to locate each relation's parent-key column, then every relation's
children are batch-loaded (one extra query per relation) and grouped, and the
second pass resolves each relation slot to its matching children. This is the
classic preload — one query per relation level, never N+1.

### one

```saga
fun one : Connection -> Prepared a -> Result (Maybe a) DbError needs {Repo}
```

Execute a prepared query and decode the first row, if any. Returns `Ok Nothing`
when the result set is empty. For a query with `preload`ed relations, children are
loaded only for the returned row, not for every row the query matched. (The query
itself still runs unbounded — add `limit! 1` if you want the database to stop at
one row too.)

### exactly_one

```saga
fun exactly_one : Connection -> Prepared a -> Result a DbError needs {Repo}
```

Execute a prepared query expecting *exactly one* row. Unlike `one` (which yields
`Maybe`), this fails with `ExpectedOneRow n` when the result set is empty or has
more than one row — for queries where any other count is a real error (a lookup
by primary key, an aggregate, a `RETURNING` from a single-row write). The row count
is checked before decoding, so a wrong count never loads relations or decodes rows.

### has_many

```saga
fun has_many : Table ccols -> pcols -> pk -> ccols -> ck -> Relation pcols ccols child k where {k: Core.PgType + Eq, pk: ToSql k, ck: ToSql k, ccols: Generic ccols_rep, ccols_rep: Selectable child_rep, child: Generic child_rep}
```

Define a has-many relation: a parent-key column matched to the child's foreign-key
column. The generated child query selects each child paired with its FK
(`SELECT child_fk, <child cols> FROM child WHERE child_fk IN (keys)`) and groups the
result; nested relations on the child load too, since the child query runs through
the ordinary `all`. Consume with `preload` → `List child`.

### belongs_to

```saga
fun belongs_to : Table ccols -> pcols -> pk -> ccols -> ck -> RelationOne pcols ccols child k where {k: Core.PgType + Eq, pk: ToSql k, ck: ToSql k, ccols: Generic ccols_rep, ccols_rep: Selectable child_rep, child: Generic child_rep}
```

Define a belongs-to relation: the parent holds the foreign key pointing at the
child's key (e.g. a post's `author_id` → a user's `id`). Consume with `preload`
→ `Maybe child`.

post_author = Db.belongs_to users (fun p -> p.author_id) (fun u -> u.id)

### has_one

```saga
fun has_one : Table ccols -> pcols -> pk -> ccols -> ck -> RelationOne pcols ccols child k where {k: Core.PgType + Eq, pk: ToSql k, ck: ToSql k, ccols: Generic ccols_rep, ccols_rep: Selectable child_rep, child: Generic child_rep}
```

Define a has-one relation: like `has_many` (the child holds the foreign key) but at
most one child per parent. Consume with `preload` → `Maybe child`.

### preload

```saga
fun preload : rel -> pcols -> Preloaded out needs {QueryBuild} where {rel: Preloadable pcols ccols out}
```

Pull a relation into the current query as a `select` field. The relation's declared
kind picks the result shape — `has_many` → `List child`, `belongs_to`/`has_one` →
`Maybe child` — so there's nothing to choose at the call site. The parent-key column
is added to the SELECT automatically, and the children are batch-loaded by
`all`/`one` after the main query — one extra query per relation, not N+1.

let u = from! users
let posts = preload authored_posts u      -- Preloaded (List Post)
select ({ user: u, posts: posts })

let p = from! posts
let author = preload post_author p        -- Preloaded (Maybe User)
select ({ post: p, author: author })

### preload_where

```saga
fun preload_where : rel -> pcols -> ccols -> Expr -> Preloaded out needs {QueryBuild} where {rel: Preloadable pcols ccols out}
```

Like `preload`, but scopes the loaded children with a predicate over the child's
columns — `AND`-ed into the generated child query's `WHERE`. Only matching children
are loaded and stitched; parents with none get `[]` (or `Nothing` for a to-one).

let posts = preload_where authored_posts u (fun p -> Db.eq p.published True)
select ({ user: u, posts: posts })       -- each user's *published* posts

### transaction

```saga
fun transaction : Connection -> Unit -> Result a e needs {Repo, Rollback e} -> Result a (TransactionError e) needs {Transaction}
```

Run `body` inside a database transaction. Every Kraken operation the body
performs against `conn` (via `all`/`one`/`exec`/the DML helpers) automatically
joins the transaction. The transaction commits if `body` returns `Ok` and rolls
back if it returns `Err`.

Body errors are returned as `RolledBack e`; failures before the body starts
are returned as `TransactionFailed QueryError`. `rollback! e` is available
inside the body for an early non-resuming rollback.

Caveat (from saga_pgo): don't let a continuation captured inside `body` escape
and run later — its re-invocation happens after commit/rollback, outside the
transaction.
