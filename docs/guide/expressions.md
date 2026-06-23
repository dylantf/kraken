# Expressions

Kraken expressions are typed SQL fragments. A `Db.Col a`, `Db.Generated a`, and
`Db.Sql a` can all be used in comparisons, ordering, grouping, and selection.

## Literals and SQL arguments

Use literal-taking helpers for the common case:

```saga
Db.eq u.name "Alice"
Db.gt u.age 18
Db.like u.name "A%"
```

Use `Db.sql` when a function takes a list of SQL arguments, and `Db.value` for a
bound literal argument:

```saga
Db.concat [Db.sql (Db.lit "user:"), Db.sql u.name]
```

`Db.lit` emits a typed parameter with an explicit cast, useful when Postgres
cannot infer the parameter type.

## Comparisons

Literal right-hand side:

```saga
Db.eq u.name "Alice"
Db.not_eq u.name "Bob"
Db.gt u.age 18
Db.gte u.age 18
Db.lt u.age 65
Db.lte u.age 65
```

SQL-to-SQL comparisons:

```saga
Db.eq_col p.author_id u.id
Db.not_eq_sql p.id other.id
Db.gt_sql u.age (Db.scalar_subquery (fun () -> {
  let _ = from! posts
  Db.count_star
}))
```

## Boolean composition

```saga
Db.and_ [Db.gt u.age 18, Db.like u.name "A%"]
Db.or_ [Db.eq u.name "Alice", Db.eq u.name "Bob"]
Db.not_ (Db.eq u.age 0)
```

An empty `and_ []` is `TRUE`. Avoid empty `or_ []` unless that behavior is
explicitly what you want.

## Lists and ranges

```saga
Db.in_ u.name ["Alice", "Bob"]
Db.not_in u.name ["Eve"]
Db.between u.age 18 65
```

Empty lists are handled:

- `Db.in_ col []` renders `FALSE`
- `Db.not_in col []` renders `TRUE`

Postgres `ANY` / `ALL` helpers:

```saga
Db.eq_any u.id [1, 2, 3]
Db.not_eq_all u.id [4, 5]
Db.like_any u.name ["A%", "B%"]
Db.ilike_any u.name ["a%", "b%"]
```

## Text functions

```saga
Db.lower u.name
Db.upper u.name
Db.trim u.name
Db.concat [Db.sql u.name, Db.value ":", Db.sql (Db.as_text u.id)]
```

## Arithmetic

Literal right-hand side:

```saga
Db.add u.age 1
Db.sub u.age 1
Db.mul u.age 2
Db.div u.age 2
```

SQL-to-SQL:

```saga
Db.add_sql invoice.subtotal invoice.tax
```

## CASE

`Db.case_when` returns `Db.Sql a`, so the result type may need an annotation:

```saga
select ({
  tier: (Db.case_when [
    (Db.gte u.age 65, Db.sql (Db.lit "senior")),
    (Db.gte u.age 18, Db.sql (Db.lit "adult")),
  ] (Db.sql (Db.lit "minor")) : Db.Sql String),
})
```

## Casts

Use `Db.cast` when the target type is fixed by annotation, or one of the helper
casts when possible:

```saga
Db.as_text u.age
Db.as_int some_expr
Db.as_float some_expr
Db.as_bool some_expr
Db.as_timestamp some_expr
Db.as_date some_expr
Db.as_time some_expr
```

The target type must have `Db.PgType + Db.PgTypeName`.

## Aggregates

```saga
Db.count_star
Db.count p.id
Db.count_distinct p.author_id
Db.sum u.age
Db.avg u.age
Db.min u.age
Db.max u.age
```

`count` and `count_star` decode as `Int`.

`sum`, `avg`, `min`, and `max` decode as `Maybe ...` because SQL returns `NULL`
for empty aggregate inputs.

## Arrays

Declare array columns as `Db.Col (Db.Array a)`.

```saga
record Posts {
  tags: Db.Col (Db.Array String),
}
```

Bind arrays with `Db.array`:

```saga
where_! (Db.contains p.tags (Db.array ["saga"]))
where_! (Db.overlaps p.tags (Db.array ["db", "query"]))
where_! (Db.contained_by p.tags (Db.array ["saga", "db", "query"]))
```

After decoding, use `Db.array_to_list`.

## JSONB

Declare JSONB columns as `Db.Col (Db.Jsonb a)` where `a` has JSON codecs:

```saga
record Metadata {
  source: String,
  featured: Bool,
} deriving (ToJson, FromJson)

record Posts {
  metadata: Db.Col (Db.Jsonb Metadata),
}
```

Operators:

```saga
Db.json_contains p.metadata (Db.jsonb (Metadata {
  source: "seed",
  featured: True,
}))

Db.json_has_key p.metadata "source"
Db.json_text p.metadata "source"
```

After decoding, use `Db.jsonb_to_value`.

## Raw SQL

Use raw SQL for gaps in the expression vocabulary:

```saga
Db.raw "COALESCE(?, ?)" [Db.sql u.name, Db.value "anonymous"] : Db.Sql String
```

Use `Db.expr_raw` for predicates:

```saga
where_! (Db.expr_raw "length(?) > ?" [Db.sql u.name, Db.value 3])
```

Question marks are replaced by typed SQL arguments. Kraken validates the
placeholder count at runtime when building the fragment.

Raw SQL is an escape hatch. It preserves parameter binding but Postgres still
validates the SQL string.

## Window functions

Build windows from `Db.window`:

```saga
select ({
  id: u.id,
  age: u.age,
  age_rank: Db.row_number (Db.order_window [Db.desc u.age] Db.window),
  peers: Db.over Db.count_star (Db.partition_by [Db.group u.age] Db.window),
})
```

Available helpers:

```saga
Db.row_number window
Db.rank window
Db.dense_rank window
Db.lag u.age window
Db.lead u.age window
Db.over aggregate window
```

`lag` and `lead` decode as `Maybe a`.
