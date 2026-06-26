# Relations

Kraken has two relation tools:

1. SQL joins, where the relation is part of the main query.
2. Preloads, where the parent rows are fetched first and children are loaded in a
   second batched query.

Use joins when the related table participates in filtering, ordering, grouping,
or selecting a few scalar fields. Use preloads when you want nested results
without N+1 queries.

## Inner joins

```saga
pub fun user_posts_query : Unit -> Db.Prepared { user: User, title: String }
user_posts_query () = Db.query (fun () -> {
  let u = from! users
  let p = inner_join! posts (fun ps -> Db.eq_col ps.author_id u.id)
  where_! (Db.eq p.published True)
  order_by! [Db.desc p.id]
  select ({ user: u, title: p.title })
})
```

The `ON` callback receives the joined table's plain columns. The result of
`inner_join!` is also plain columns, because an inner join only returns matched
rows.

## Left joins

```saga
pub fun users_with_optional_posts_query : Unit
  -> Db.Prepared { user: User, post: Maybe Post }
users_with_optional_posts_query () = Db.query (fun () -> {
  let u = from! users
  let p = left_join! posts (fun ps ->
    Db.and_ [Db.eq_col ps.author_id u.id, Db.eq ps.published True])
  order_by! [Db.asc u.id]
  select ({ user: u, post: p })
})
```

Selecting the left-joined scope `p` decodes `Maybe Post`.

If the selected row's columns are all `NULL`, Kraken decodes `Nothing`.
Otherwise it decodes the row and wraps it in `Just`.

## Anti-joins

For "users with no posts", left join and filter for a null joined key:

```saga
pub fun users_without_posts_query : Unit
  -> Db.Prepared { id: Int, name: String }
users_without_posts_query () = Db.query (fun () -> {
  let u = from! users
  let p = left_join! posts (fun ps -> Db.eq_col ps.author_id u.id)
  where_! (Db.is_null (Db.unwrap_cols p).id)
  order_by! [Db.asc u.id]
  select ({ id: u.id, name: u.name })
})
```

`Db.unwrap_cols` is only for predicates, ordering, grouping, and expressions
that need to point at the physical nullable-side columns. Do not select
`Db.unwrap_cols p`; selecting the nullable scope itself is what gives `Maybe
Post`.

Often, `Db.not_exists` is a cleaner anti-join:

```saga
where_! (Db.not_exists (fun () -> {
  let p = from! posts
  where_! (Db.eq_col p.author_id u.id)
}))
```

## Full joins

Full joins are symmetric: either side may be missing. Use `Db.full_join_query`:

```saga
pub fun users_full_join_posts_query : Unit
  -> Db.Prepared { user: Maybe User, post: Maybe Post }
users_full_join_posts_query () = (
  Db.full_join_query users posts
    (fun u p -> Db.eq_col p.author_id u.id)
    (fun (user_scope, post_scope) -> {
      select ({ user: user_scope, post: post_scope })
    })
)
```

Both scopes are nullable, so selecting them decodes `Maybe User` and
`Maybe Post`.

## Declaring has-many relations

A relation names the parent key and child foreign key once:

```saga
pub fun authored_posts : Db.Relation Users Posts Post Int
authored_posts = (
  Db.has_many posts
    (fun u -> u.id)
    (fun p -> p.author_id)
)
```

The relation type says:

- parent columns: `Users`
- child columns: `Posts`
- decoded child row: `Post`
- key type: `Int`

## Preload has-many

Use `Db.preload` inside a query:

```saga
pub fun users_with_posts_query : Unit
  -> Db.Prepared { user: User, posts: List Post }
users_with_posts_query () = Db.query (fun () -> {
  let u = from! users
  let posts = Db.preload authored_posts u
  order_by! [Db.asc u.id]
  select ({ user: u, posts: posts })
})
```

`Db.all` runs the parent query, then one child query for all parent keys, and
stitches children by key. This avoids N+1 queries.

The rendered parent SQL includes a hidden internal key column such as:

```sql
SELECT t0.id AS __kraken_rel0_key, t0.id AS user_id, ...
```

That column is for relation stitching and is not part of the decoded user-facing
shape.

## Preload filters

Use `Db.preload_where` to scope loaded children:

```saga
pub fun users_with_published_posts_only_query : Unit
  -> Db.Prepared { user: User, posts: List Post }
users_with_published_posts_only_query () = Db.query (fun () -> {
  let u = from! users
  let posts =
    Db.preload_where authored_posts u (fun p -> Db.eq p.published True)
  order_by! [Db.asc u.id]
  select ({ user: u, posts: posts })
})
```

Parents with no matching children decode `posts: []`.

## Many-to-many relations

Use `Db.has_many_through` when a relation is reached through a join table.
For example, sessions have many gear items through `sesh_gear`:

```saga
pub fun sesh_gear_items : Db.RelationThrough Seshes SeshGear Gears Gear Int Int
sesh_gear_items = (
  Db.has_many_through sesh_gear gear
    (fun s -> s.id)
    (fun sg -> sg.sesh_id)
    (fun sg -> sg.gear_id)
    (fun g -> g.id)
)
```

Then preload it like any other to-many relation:

```saga
pub fun seshes_with_gear_query : Unit
  -> Db.Prepared { sesh: Sesh, gear: List Gear }
seshes_with_gear_query () = Db.query (fun () -> {
  let s = from! seshes
  let gear = Db.preload sesh_gear_items s
  select ({ sesh: s, gear: gear })
})
```

The generated relation query joins through the link table and groups by the
parent key:

```sql
SELECT sg.sesh_id, gear.*
FROM sesh_gear AS sg
INNER JOIN gear ON sg.gear_id = gear.id
WHERE sg.sesh_id IN (...)
```

Define the reverse direction as a second relation with the accessors swapped:

```saga
pub fun gear_seshes : Db.RelationThrough Gears SeshGear Seshes Sesh Int Int
gear_seshes = (
  Db.has_many_through sesh_gear seshes
    (fun g -> g.id)
    (fun sg -> sg.gear_id)
    (fun sg -> sg.sesh_id)
    (fun s -> s.id)
)
```

Use `Db.preload_where` to filter the target table:

```saga
let recent_seshes = Db.preload_where gear_seshes g (fun s -> Db.gte s.date cutoff)
```

If the join table has meaningful payload, model it as its own table and preload
that directly rather than hiding it behind a through relation.

## To-one relations

Use `Db.belongs_to` when the parent holds the foreign key:

```saga
pub fun post_author : Db.RelationOne Posts Users User Int
post_author = (
  Db.belongs_to users
    (fun p -> p.author_id)
    (fun u -> u.id)
)
```

Then preload:

```saga
pub fun posts_with_author_query : Unit
  -> Db.Prepared { post: Post, author: Maybe User }
posts_with_author_query () = Db.query (fun () -> {
  let p = from! posts
  let author = Db.preload post_author p
  order_by! [Db.asc p.id]
  select ({ post: p, author: author })
})
```

To-one preloads decode `Maybe child`, because the related row may be absent.

Use `Db.has_one` when the child holds the foreign key but you expect at most one
child per parent.

## Execution and cardinality

Preloads are resolved by `Db.all`, `Db.one`, and `Db.exactly_one`.

- `Db.all` loads children for every returned parent row.
- `Db.one` loads children only for the first row it keeps.
- `Db.exactly_one` checks row count before decoding or loading relations.

Nested relation preloads work through the same mechanism: a child query is just
another Kraken query.
