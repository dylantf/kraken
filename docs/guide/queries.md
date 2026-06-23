# Queries

Build a query with `Db.query`. The body is normal Saga code plus `QueryBuild`
effect operations.

```saga
pub fun users_query : Unit -> Db.Prepared { id: Int, name: String, age: Int }
users_query () = Db.query (fun () -> {
  let u = from! users
  where_! (Db.gt u.age 18)
  order_by! [Db.asc u.id]
  limit! 20
  select ({ id: u.id, name: u.name, age: u.age })
})
```

Every query body returns `select value`. The selected value determines the
decoded row type.

## FROM

`from!` binds a table and returns its column record:

```saga
let u = from! users
```

Use fields on that record to refer to columns:

```saga
u.id
u.name
u.age
```

## SELECT

Select individual columns:

```saga
select ({ id: u.id, name: u.name })
```

Select a whole row:

```saga
select u
```

Mix whole rows and scalar fields:

```saga
select ({ user: u, title: p.title })
```

The aliases come from the selection labels. Whole rows are prefixed by the label
when embedded:

```sql
SELECT t0.id AS user_id, t0.name AS user_name, ...
```

## WHERE

Call `where_!` as many times as you need. Repeated predicates are combined with
`AND`.

```saga
where_! (Db.eq u.name "Alice")
where_! (Db.gt u.age 18)
where_! (Db.like u.name "A%")
```

Because the query body is ordinary code, dynamic filters are direct:

```saga
case min_age {
  Just n -> where_! (Db.gt u.age n)
  Nothing -> ()
}

if newest_first then order_by! [Db.desc u.id] else order_by! [Db.asc u.id]
```

## Ordering, limits, offsets

```saga
order_by! [Db.asc u.name, Db.desc u.id]
limit! 20
offset! 40
```

`Db.asc` and `Db.desc` accept columns or SQL expressions.

## Joins

`inner_join!` receives the joined table's plain column record in the `ON`
callback and returns the joined table's columns:

```saga
let p = inner_join! posts (fun ps -> Db.eq_col ps.author_id u.id)
select ({ user: u, title: p.title })
```

`left_join!` returns a nullable scope. Selecting the whole scope decodes
`Maybe row`:

```saga
let p = left_join! posts (fun ps -> Db.eq_col ps.author_id u.id)
select ({ user: u, post: p })
# { user: User, post: Maybe Post }
```

Use `Db.unwrap_cols` only in predicate/order/expression positions where SQL needs
the physical column:

```saga
where_! (Db.is_null (Db.unwrap_cols p).id)
select ({ id: u.id, name: u.name })
```

Do not select the result of `unwrap_cols`; that bypasses the `Maybe` decode.

## Distinct

Plain `SELECT DISTINCT`:

```saga
distinct! ()
select ({ age: u.age })
```

Postgres `DISTINCT ON`:

```saga
distinct_on! [Db.group u.age]
order_by! [Db.asc u.age, Db.desc u.id]
select ({ id: u.id, name: u.name, age: u.age })
```

The order matters in Postgres: the `ORDER BY` decides which row wins each
distinct group.

## Grouping and HAVING

```saga
let p = from! posts
group_by! [Db.group p.author_id]
having! (Db.gt_sql Db.count_star (Db.lit 1))
order_by! [Db.desc Db.count_star]
select ({ author_id: p.author_id, posts: Db.count_star })
```

Kraken does not currently type-check SQL grouping rules. If you select a
non-grouped, non-aggregated column, Postgres will reject the query.

## EXISTS

Correlated subqueries can reference outer columns directly:

```saga
where_! (Db.exists (fun () -> {
  let p = from! posts
  where_! (Db.and_ [
    Db.eq_col p.author_id u.id,
    Db.eq p.published True,
  ])
}))
```

Use `Db.not_exists` for `NOT EXISTS`.

## IN subqueries

For `IN (SELECT ...)`, the closure returns the single selected column instead of
using `select`:

```saga
where_! (Db.in_subquery u.id (fun () -> {
  let p = from! posts
  where_! (Db.eq p.published True)
  p.author_id
}))
```

The left side and returned column must have the same type.

## Derived tables

Use `Db.from_subquery` for a subquery in `FROM`. The inner `select` labels become
columns on the derived table:

```saga
let t = Db.from_subquery (fun () -> {
  let p = from! posts
  group_by! [Db.group p.author_id]
  select ({ author_id: p.author_id, posts: Db.count_star })
})

where_! (Db.gt t.posts 5)
select ({ author_id: t.author_id, posts: t.posts })
```

## CTEs

Use `Db.cte` to define a named CTE and get back a table handle:

```saga
let counts = Db.cte "post_counts" (fun () -> {
  let p = from! posts
  group_by! [Db.group p.author_id]
  select ({ author_id: p.author_id, posts: Db.count_star })
})

let c = from! counts
where_! (Db.gt c.posts 5)
select ({ author_id: c.author_id, posts: c.posts })
```

## Scalar subqueries

Use `Db.scalar_subquery` when the subquery returns one non-null value:

```saga
select ({
  id: u.id,
  total_posts: Db.scalar_subquery (fun () -> {
    let _ = from! posts
    Db.count_star
  }),
})
```

Use `Db.scalar_subquery_maybe` when the subquery may return no rows:

```saga
select ({
  id: u.id,
  title: Db.scalar_subquery_maybe (fun () -> {
    let p = from! posts
    where_! (Db.eq_col p.author_id u.id)
    limit! 1
    p.title
  }),
})
```

## Execution

`Db.query` returns `Db.Prepared a`. Run it with:

```saga
Db.all conn prepared         # Result (List a) DbError
Db.one conn prepared         # Result (Maybe a) DbError
Db.exactly_one conn prepared # Result a DbError
```

Provide the repo handler at the boundary:

```saga
Db.all conn (users_query ()) with Db.pg_repo
```
