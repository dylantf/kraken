# Writes

Write operations are available through `Kraken.Db`. Users should not need to
import an internal write module.

This page uses the import pattern from [Getting started](getting-started.md).

Non-returning writes produce `Db.Prepared Unit` and run with `Db.exec`. Writes
with `RETURNING` produce `Db.Prepared row` and run with `Db.all`, `Db.one`, or
`Db.exactly_one`.

## Insert

Use the insert shape synthesized by `Core.Insertable`:

```saga
pub fun insert_user_query : Unit -> Db.Prepared Unit
insert_user_query () =
  Db.insert users (UsersInsert {
    id: Db.auto,
    name: "Carol",
    age: 31,
  })
```

`Db.auto` omits a generated column. `Db.provide value` binds one explicitly.

Run a non-returning insert with `Db.exec`:

```saga
Db.exec conn (insert_user_query ()) with Db.pg_repo
```

## Insert returning

Return the whole inserted row:

```saga
pub fun insert_user_returning : Unit -> Db.Prepared User
insert_user_returning () = {
  let row = UsersInsert { id: Db.auto, name: "Carol", age: 31 }
  Db.insert_returning users row (fun u -> u)
}
```

Return selected fields:

```saga
pub fun insert_user_returning_id : Unit -> Db.Prepared { id: Int }
insert_user_returning_id () = {
  let row = UsersInsert { id: Db.auto, name: "Carol", age: 31 }
  Db.insert_returning users row (fun u -> { id: u.id })
}
```

Run it with a query executor:

```saga
Db.one conn (insert_user_returning ())
```

## Bulk insert

```saga
Db.insert_all users [
  UsersInsert { id: Db.auto, name: "Carol", age: 31 },
  UsersInsert { id: Db.auto, name: "Dave", age: 40 },
]
```

`Db.insert_all []` is a no-op prepared statement. `Db.exec` returns `Ok 0` and
`Db.all` returns `Ok []` without a database round trip.

Bulk inserts need one shared column list. Do not mix `Db.auto` and `Db.provide`
for the same generated column across rows in a single call.

Bulk returning:

```saga
Db.insert_all_returning users rows (fun u -> { id: u.id })
```

## Update

Use the `Update` effect operations inside the callback:

```saga
pub fun bump_age_query : Unit -> Db.Prepared Unit
bump_age_query () = Db.update users (fun u -> {
  set! u.age 43
  where_! (Db.eq u.id 1)
})
```

Repeated `where_!` calls are combined with `AND`.

Returning:

```saga
Db.update_returning users (fun u -> {
  set! u.age 43
  where_! (Db.eq u.id 1)
}) (fun u -> u)
```

## Whole-row update

If the table has a primary key and the domain record derives `InsertRow`, use
`Db.update_all` for a save-style update:

```saga
pub fun save_user_query : User -> Db.Prepared Unit
save_user_query user = Db.update_all users user
```

`update_all` updates every non-key field and builds the `WHERE` from the
`primary_key` declared in `ColumnSet`.

## Delete

```saga
pub fun delete_user_query : Unit -> Db.Prepared Unit
delete_user_query () =
  Db.delete users (fun u -> Db.eq u.id 999)
```

Returning:

```saga
(
  Db.delete_returning users
    (fun u -> Db.eq u.id 999)
    (fun u -> u)
)
```

## Insert or ignore

Use `Db.insert_on_conflict_do_nothing`:

```saga
let row = UsersInsert { id: Db.auto, name: "Carol", age: 31 }
Db.insert_on_conflict_do_nothing users row (fun u -> [Db.ref u.name])
```

The target callback names conflict columns with `Db.ref`.

Returning version:

```saga
(
  Db.insert_on_conflict_do_nothing_returning users row
    (fun u -> [Db.ref u.name])
    (fun u -> u)
)
```

If the row conflicts, Postgres returns no row, so `Db.one` yields `Ok Nothing`.

## Upsert

Default upsert overwrites every inserted non-target column with `EXCLUDED`:

```saga
let row = UsersInsert { id: Db.provide 1, name: "Carol", age: 31 }
Db.upsert users row (fun u -> [Db.ref u.id])
```

Returning version:

```saga
Db.upsert_returning users row (fun u -> [Db.ref u.id]) (fun u -> u)
```

## Custom upsert

Use `Db.upsert_set` when you want explicit assignments:

```saga
let row = UsersInsert { id: Db.provide 1, name: "Carol", age: 31 }

(
  Db.upsert_set users row
    (fun u -> Db.on_columns [Db.ref u.id])
    (fun u -> [
      Db.assign u.age (Db.add u.age 1),
      Db.assign u.name (Db.excluded u.name),
    ])
)
```

Use a named constraint:

```saga
(
  Db.upsert_set users row
    (fun _ -> Db.on_constraint "users_pkey")
    (fun u -> [Db.assign u.age (Db.excluded u.age)])
)
```

## Transactions

Wrap several operations in `Db.transaction`:

```saga
pub fun atomic_writes : Connection -> Result Int (Db.TransactionError Db.DbError) needs {Transaction}
atomic_writes conn = Db.transaction conn (fun () -> {
  let new_row = UsersInsert { id: Db.auto, name: "Dave", age: 40 }
  case Db.exec conn (Db.insert users new_row) {
    Err err -> Err err
    Ok inserted -> case Db.exec conn (bump_age_query ()) {
      Err err -> Err err
      Ok bumped -> Ok (inserted + bumped)
    }
  }
})
```

The transaction commits when the body returns `Ok` and rolls back when the body
returns `Err`. Body errors are returned as `RolledBack err`; failures before the
body starts, such as failing to begin the transaction, are returned as
`TransactionFailed query_error`.

`Db.transaction` is generic in the error type. Import `Rollback` when you want
an early non-resuming rollback:

```saga
import Kraken.Db (Rollback, Transaction)

Db.transaction conn (fun () -> {
  if invalid then rollback! (Validation "bad data")
  else Ok ()
})
```

At the application boundary, provide `pg_transaction` and `pg`:

```saga
atomic_writes conn with {pg_transaction, pg}
```
