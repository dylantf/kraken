# SQL Coverage And Query Expressivity

Date: 2026-06-17

This is a working plan for the higher-level Kraken query builder. The goal is
not to implement all of SQL, but to decide which subset Kraken should own with
types, and where raw SQL remains the escape hatch.

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
- typed SQL value expressions with `Sql a`
- `group_by!`
- `having!`
- basic aggregate helpers: `count_star`, `count`, `count_distinct`, `sum`,
  `avg`, `min`, `max`
- query execution through `all` and `one`

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

Left joins currently work for nullable scalar fields by giving left-joined
tables an optional column scope:

```saga
Db.query (fun () -> {
  let u = from! users
  let p = left_join! posts (fun post -> Db.eq_col post.author_id u.id)

  select! ({
    user: u,
    post_id: p.id,
    post_title: p.title,
  })
})
```

The inferred row shape is:

```saga
{
  user: User,
  post_id: Maybe Int,
  post_title: Maybe String,
}
```

Whole-row optional projection, such as `post: p` into `Maybe Post`, is still a
future design/compiler item.

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
where_! (Db.raw_expr_from [
  Db.sql_column p.title,
  Db.sql_text " LIKE ",
  Db.sql_value "Hello%",
])

select! ({ total: Db.select_raw "COUNT(*)" })
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

- `distinct!`

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

- `Column source name a`
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

pub fun sql_raw : String -> Sql a where {a: PgType}
pub fun sql_raw_from : List Fragment -> Sql a where {a: PgType}
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
- `count : Column source name a -> Sql Int`
- `count_distinct : Column source name a -> Sql Int`
- `sum`
- `avg`
- `min`
- `max`

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

## Tier 4: Predicate Vocabulary

Useful helpers to add once `Sql a` exists:

- `in_`
- `not_in`
- `like`
- `ilike`
- `between`
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
```

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

But this can wait until real use cases show up.

## Tier 6: Subqueries

Raw SQL can cover early needs:

```saga
select! ({
  latest_title: Db.select_raw "(SELECT title FROM posts ORDER BY id DESC LIMIT 1)"
})
```

Typed subqueries split into several features:

- scalar subquery as `Sql a`
- `EXISTS`
- `IN (subquery)`
- derived table / subquery join

Possible future syntax:

```saga
where_! (Db.exists (fun () -> {
  let p = from! posts
  where_! (Db.eq_col p.author_id u.id)
  select! ({ one: Db.select_raw "1" })
}))
```

Derived tables are a larger design because a subquery needs to become a table
scope with generated columns.

## Tier 7: DML

Separate builder family:

- `insert`
- `insert_many`
- `update`
- `delete`
- `returning`

Possible shape:

```saga
Db.insert users {
  name: "Alice",
  age: 42,
}

Db.update users (fun u -> {
  set! u.name "Alice Updated"
  where_! (Db.eq u.id 1)
})

Db.delete users (fun u -> {
  where_! (Db.eq u.id 1)
})
```

The existing `Table table row insert ...` type parameters should help here, but
the insert/update APIs need their own planning.

## Open Design Questions

### Should `Sql a` Replace `SelectExpr a`?

Decision: yes.

`Sql a` now carries the fragment and decoder needed for selection, so
`SelectExpr a` is redundant. Aliasing should come from anonymous record labels:

```saga
select! ({ total: Db.count_star })
select! ({ lower_name: Db.sql_raw "LOWER(t0.name)" })
```

The default alias for selecting a bare `Sql a` is still `value`, but the preferred
surface API is to put raw or computed expressions behind record labels.

### How Should Whole-Row Optional Left Joins Work?

Desired syntax:

```saga
let p = left_join! posts (fun p -> Db.eq_col p.author_id u.id)

select! ({
  user: u,
  post: p,
})
```

Desired result:

```saga
{
  user: User,
  post: Maybe Post,
}
```

Scalar optional columns already work. Whole-row optional projection needs a
library/compiler-friendly way to map a row of `Maybe` fields into `Maybe Post`.

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

After `Sql a`, grouping, having, and basic aggregates, the next useful steps
are:

- `distinct!`
- predicate helpers like `like`, `ilike`, `between`, `in_`
- casts through `PgTypeName a`
- whole-row optional left join projection, such as `post: Maybe Post`

This continues growing the SQL surface on top of the typed expression model
instead of adding one-off APIs.
