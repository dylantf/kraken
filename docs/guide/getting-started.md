# Getting started

Kraken is a typed PostgreSQL query builder for Saga. It gives table and
column references real Saga types, so common mistakes are caught before the
query reaches Postgres:

- selecting `u.name` decodes as `String`
- comparing `u.id` to a `String` does not typecheck
- selecting a whole left-joined row decodes as `Maybe Row`
- generated columns can be read, filtered, and ordered, but inserts omit them
  unless you explicitly provide a value

The public module is `Kraken.Db`. Qualified calls use the module's final
segment, `Db`.

## Install

Add Kraken and its runtime dependencies to your `project.toml`:

```toml
[dependencies]
kraken = { git = "https://github.com/dylantf/kraken" }
saga_pgo = { git = "https://github.com/dylantf/saga_pgo" }
saga_json = { git = "https://github.com/dylantf/saga_json" }
```

Then run `saga install`.

## Imports used in this guide

Most examples assume this import set:

```saga
import Kraken.Db (QueryBuild, Repo, select)
import Kraken.Query
import SagaPgo (Connection)
```

## Define a table

Start with the row you want queries to decode:

```saga
record User {
  id: Int,
  name: String,
  age: Int,
}
```

Then define a column record for the table. This is the typed scope that `from!`
returns:

```saga
record Users {
  id: Db.Generated Int,
  name: Db.Col String,
  age: Db.Col Int,
} deriving (Selectable User)
```

`Db.Generated a` is a readable column that the database usually fills in.
`Selectable User` says that selecting the whole `Users` scope decodes a
`User`.

Map the column record to the SQL table:

```saga
impl ColumnSet for Users {
  columns source = Users {
    id: Db.generated "id" source,
    name: Db.col "name" source,
    age: Db.col "age" source,
  }
}

pub fun users : Db.Table Users
users = Db.table "users"
```

The first string in `Db.col "name" source` is the real SQL column name. The
record field name is the Saga field (`u.name`) and the default select alias.

That is enough for read queries. For inserts and save-style updates, add the
write derives described in the [schema](schema.md) and [writes](writes.md)
guides.

## Query

Define a query with `Db.query`. The type annotation says what each returned row
will decode to:

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

Inside the query body, `from!`, `where_!`, `order_by!`, and `limit!` build SQL.
The final `select` names the values to decode from each row.

The selected record determines the decoded row type:

```saga
{ id: Int, name: String, age: Int }
```

`Db.query` returns a `Db.Prepared row`: rendered SQL, bound parameters, and a
decoder for `row`. You pass that prepared query to `Db.all`, `Db.one`, or
`Db.exactly_one` to run it.

## Anonymous record projections

Kraken uses anonymous records as the normal way to shape query results. In a
`select`, the labels you write become fields on the decoded row:

```saga
select ({ id: u.id, display_name: u.name })
```

That query returns rows shaped like:

```saga
{ id: Int, display_name: String }
```

You can select expressions, columns, whole rows, and preloaded relations in the
same anonymous record:

```saga
select ({
  user: u,
  title: p.title,
  age_text: Db.as_text u.age,
})
```

The decoded row type is:

```saga
{ user: User, title: String, age_text: String }
```

Whole-row selections use the table's `Selectable` derive. Scalar fields use
their column or SQL expression type. This gives query-local result shapes without
defining a new named record for every query.

Anonymous records are not required. If a result shape is part of your domain or
is reused across modules, define a named record and map into it with `Db.into`:

```saga
record UserSummary {
  id: Int,
  name: String,
}

pub fun user_summaries : Unit -> Db.Prepared UserSummary
user_summaries () =
  Db.query (fun () -> {
    let u = from! users
    select ({ id: u.id, name: u.name })
  })
  |> Db.into (fun row -> UserSummary {
    id: row.id,
    name: row.name,
  })
```

Use anonymous records for local query shapes; use named records when the shape
deserves a name in your application API.

Select a whole table scope to decode a domain record:

```saga
pub fun active_users : Unit -> Db.Prepared User
active_users () = Db.query (fun () -> {
  let u = from! users
  where_! (Db.gt u.age 18)
  select u
})
```

## Execute

Use `Db.all`, `Db.one`, or `Db.exactly_one` with a `Connection`.

```saga
pub fun load_users : Connection
  -> Result (List { id: Int, name: String, age: Int }) Db.DbError
  needs {Repo}
load_users conn = Db.all conn (users_query ())
```

At the application boundary, provide the repo handler:

```saga
let rows = load_users conn with Db.pg_repo
```

## Inspect SQL

A prepared query carries the rendered SQL and parameters:

```saga
let prepared = users_query ()
prepared.sql
prepared.params
```

This is useful for logging and for checking what the builder produced. Kraken
numbers parameters at render time, so nested subqueries and CTEs still produce
`$1`, `$2`, ... in the final SQL order.

## Next

- [Schema](schema.md) explains the table setup and insert-shape derives.
- [Queries](queries.md) covers joins, grouping, subqueries, CTEs, and execution.
- [Expressions](expressions.md) covers predicates, raw SQL, JSONB, arrays, and
  window functions.
- [Writes](writes.md) covers insert, update, delete, upsert, and transactions.
- [Relations](relations.md) covers preloads and nullable joins.
