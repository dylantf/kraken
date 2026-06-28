# Schema

Kraken separates three ideas:

1. A domain record: the value your application decodes.
2. A column record: typed handles for table columns.
3. A `ColumnSet` impl: the runtime mapping from Saga fields to SQL table and
   column names.

This gives you typed query construction without asking users to write projection
impls by hand.

## Domain records

A domain record is ordinary Saga data:

```saga
record User {
  id: Int,
  name: String,
  age: Int,
}
```

No derive is required just to name the data shape. Query decoding is connected
by the column record's `Selectable User` derive.

## Column records

A column record mirrors the table shape, but fields are typed column handles:

```saga
record Users {
  id: Db.Generated Int,
  name: Db.Col String,
  age: Db.Col Int,
} deriving (Selectable User)
```

Use `Db.Col a` for normal columns and `Db.Generated a` for columns the database
normally fills in, such as serial ids.

The read derive does one job:

- `Selectable User`: selecting `u` decodes a `User`.

That is enough for reads:

```saga
select u  # User
```

## Write derives

For inserts, add `Insertable <Name>` and `ColumnNameMap` to the column
record:

```saga
record Users {
  id: Db.Generated Int,
  name: Db.Col String,
  age: Db.Col Int,
} deriving (
  Selectable User,
  Insertable UsersInsert,
  ColumnNameMap,
)
```

These write derives do two jobs:

- `Insertable UsersInsert`: creates an insert input record from the column
  record.
- `ColumnNameMap`: lets writes translate Saga field labels to actual SQL
  column names.

The generated `UsersInsert` shape maps `Generated Int` to `Db.Writable Int` and
plain `Col a` to `a`:

```saga
UsersInsert {
  id: Db.auto,
  name: "Alice",
  age: 30,
}
```

Use `Db.auto` to omit a generated column, or `Db.provide value` to force it.

For save-style `Db.update_all`, also derive `InsertRow` on the domain
record:

```saga
record User {
  id: Int,
  name: String,
  age: Int,
} deriving (InsertRow)
```

## ColumnSet

`ColumnSet` builds the column record for a SQL source alias:

```saga
impl ColumnSet for Users {
  columns source = Users {
    id: Db.generated "id" source,
    name: Db.col "name" source,
    age: Db.col "age" source,
  }

  primary_key u = Db.key u.id
}
```

The `source` argument is the table alias Kraken assigns while rendering. You
pass it to every `Db.col` / `Db.generated` so expressions render as `t0.name`,
`t0.age`, and so on.

`primary_key` is optional, but needed by `Db.update_all`.

## Table value

Expose a table value with `Db.table`:

```saga
pub fun users : Db.Table Users
users = Db.table "users"
```

Use `Db.table_as` if you need a fixed alias:

```saga
let audited_users = Db.table_as "audited_users" users
```

Most queries should let Kraken generate aliases.

## Column names can differ from field names

The Saga field is the property users dot into; the SQL name is given in
`ColumnSet`.

```saga
record Accounts {
  id: Db.Generated Int,
  email: Db.Col String,
  status: Db.Col AccountStatus,
} deriving (Selectable Account)

impl ColumnSet for Accounts {
  columns source = Accounts {
    id: Db.generated "id" source,
    email: Db.col "email_address" source,
    status: Db.col "status" source,
  }
}
```

Users write `a.email`; SQL renders `t0.email_address`.

## Custom PostgreSQL types

Implement `Db.PgType` for custom scalar column types such as Postgres enums,
domain types, or application newtypes.

`PgType` is the database codec for a Saga type:

- `encode_pg` is used when the value becomes a bound parameter: `where_!`,
  `insert`, `update`, `upsert`, raw `Db.value`, and so on.
- `decode_pg` is used when the value comes back from a selected column or SQL
  expression.

For enum-like types stored as text labels, use `Db.enum_text_encode` and
`Db.enum_text_decode`:

```saga
type AccountStatus =
  | Active
  | Suspended
  | Closed
  deriving (Eq)

fun account_status_labels : List (AccountStatus, String)
account_status_labels = [
  (Active, "ACTIVE"),
  (Suspended, "SUSPENDED"),
  (Closed, "CLOSED"),
]

impl Db.PgType for AccountStatus {
  encode_pg value = Db.enum_text_encode account_status_labels value
  decode_pg = Db.enum_text_decode account_status_labels
}
```

If you want the compiler to check that encoding covers every constructor, write
the encode side as a normal exhaustive `case` and then encode the resulting
`String` with `Db.encode_value`:

```saga
impl Db.PgType for AccountStatus {
  encode_pg value = Db.encode_value (case value {
    Active -> "ACTIVE"
    Suspended -> "SUSPENDED"
    Closed -> "CLOSED"
  })

  decode_pg = Db.decode_via (fun label -> case label {
    "ACTIVE" -> Ok Active
    "SUSPENDED" -> Ok Suspended
    "CLOSED" -> Ok Closed
    other -> Err ("unknown account status: " <> other)
  })
}
```

`encode_pg` returns a Postgres `Value`, not the intermediate string, so returning
`"ACTIVE"` directly is a type error. `decode_pg` is a decoder value, not a direct
method that receives the raw text; `Db.decode_via` runs the built-in `String`
decoder first and then applies your conversion function. The decode side must
still handle unknown strings because the database can contain values your Saga
type does not recognize.

Then use the type directly in your domain record and column record:

```saga
record Account {
  id: Int,
  email: String,
  status: AccountStatus,
}

record Accounts {
  id: Db.Generated Int,
  email: Db.Col String,
  status: Db.Col AccountStatus,
} deriving (Selectable Account)
```

The `ColumnSet` maps `status` to the actual SQL column:

```saga
impl ColumnSet for Accounts {
  columns source = Accounts {
    id: Db.generated "id" source,
    email: Db.col "email" source,
    status: Db.col "status" source,
  }
}
```

After that, the custom type behaves like a built-in:

```saga
where_! (Db.eq a.status Active)
select a
```

This comparison encodes `Active` with `encode_pg`. Selecting `a` decodes the
`status` column with `decode_pg`.

If you have a custom wrapper that encodes through an existing `PgType`, use
`Db.encode_via` and `Db.decode_via`:

```saga
type UserId =
  | UserId Int

impl Db.PgType for UserId {
  encode_pg = Db.encode_via (fun value -> case value {
    UserId id -> id
  })
  decode_pg = Db.decode_via (fun id -> Ok (UserId id))
}
```

If you want to cast to the database type, also implement `PgTypeName`:

```saga
impl Db.PgTypeName for AccountStatus {
  pg_type_name _ = "account_status"
}
```

`PgTypeName` is only needed when Kraken has to render a cast, such as
`Db.cast`, `Db.lit`, or one of the `Db.as_*` helpers. Normal selects,
comparisons, inserts, and updates only need `PgType`.

```saga
Db.cast a.status : Db.Sql AccountStatus
```

## Arrays and JSONB

Kraken provides wrappers for Postgres arrays and JSONB:

```saga
record Metadata {
  source: String,
  featured: Bool,
} deriving (ToJson, FromJson)

record Post {
  id: Int,
  author_id: Int,
  title: String,
  published: Bool,
  tags: Db.Array String,
  metadata: Db.Jsonb Metadata,
}
```

Use `Db.array [..]` to bind an array and `Db.array_to_list` after decoding.
Use `Db.jsonb value` to bind JSONB and `Db.jsonb_to_value` after decoding.

`Db.Jsonb a` requires `a: ToJson + FromJson`, so domain JSON decoding is owned by
your Saga type.

## Module surface

Use the import pattern from [Getting started](getting-started.md). Application
code uses `Db.*` from `Kraken.Db`; the schema derives (`Selectable`,
`Insertable`, `ColumnNameMap`, `InsertRow`) and `ColumnSet` resolve through the
same `Kraken.Db` import and are written unqualified.
