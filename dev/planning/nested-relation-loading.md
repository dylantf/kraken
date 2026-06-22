# Nested / Aggregated Relation Loading (review item #5)

Date: 2026-06-21

Load a parent with its children as a nested structure (`{ user: User, posts: List
Post }`) without N+1. **Decision: the traditional separate-query approach — one
query per relation, stitched in Saga** — *not* JSON aggregation in Postgres.

## Why separate queries (not JSON)

- It's the well-trodden ORM model (Ecto `preload`, Rails `preload`, SQLAlchemy
  `selectinload`, Django `prefetch_related`): run the parent query, collect keys, run
  one child query `WHERE fk IN (keys)`, group children onto parents in app code.
- Fits Kraken's "explicit, no magic, raw SQL always available" ethos: the user writes
  two ordinary Kraken queries; Kraken only supplies the grouping.
- Sidesteps the JSON type-fidelity boundary entirely (no date/uuid → string coercion,
  no `FromJson` requirement on domain types, no `json_agg`/`COALESCE` machinery).
- saga_pgo can't decode composite arrays (rel8's encoding), and we're declining JSON,
  so plain rows + an in-memory join is the remaining — and cleanest — option.

Cost vs JSON: one extra round trip per relation *level* (not per row — this is **not**
N+1). For depth D you do D+1 queries. That's the accepted ORM tradeoff.

## What's actually new

Almost nothing. Running queries is `Query.all`; key extraction is `List.map`. The one
new primitive is the pure **stitch** that groups children onto parents by key. Plus a
thin convenience that orchestrates the child query.

### `associate` — the pure stitch (core primitive)

```saga
pub fun associate : (parent -> k) -> (child -> k) -> (parent -> List child -> r)
  -> List parent -> List child -> List r
  where {k: Eq}
```

Groups `children` by `child_key` into a `Std.Dict` (O(n+m)), then for each parent
builds `combine parent (its matching children)`. Pure, DB-free, trivially testable.
Children keep their query order within each group; a parent with no children gets `[]`
(no `Maybe` — empty is empty).

```saga
let users = ...   -- List User
let posts = ...   -- List Post (already loaded WHERE author_id IN user ids)
Query.associate (fun u -> u.id) (fun p -> p.author_id)
  (fun u ps -> { user: u, posts: ps }) users posts
-- List { user: User, posts: List Post }
```

### `preload` — convenience orchestrator (optional sugar)

```saga
pub fun preload : Connection
  -> List parent
  -> (parent -> k)                  -- parent key
  -> (List k -> Prepared child)     -- child query for those keys
  -> (child -> k)                   -- child's foreign key
  -> (parent -> List child -> r)    -- stitch
  -> Result (List r) DbError
  needs {Repo}
  where {k: Eq}
```

Extracts keys, runs the **one** child query, and `associate`s — threading `Result`.
Empty parents → `Ok []` (skips the child query). The child-query builder is where the
`Db.in_` lives, so the `k: PgType` requirement is the user's, not `preload`'s.

```saga
-- child query the user writes (one query, batched by keys):
pub fun posts_for_authors : List Int -> Prepared Post
posts_for_authors ids = Query.query (fun () -> {
  let p = from! posts
  where_! (Db.in_ p.author_id ids)
  select! (p)
})

-- load users, then their posts, in two queries:
case Query.all conn (users_query ()) {
  Err e -> Err e
  Ok users -> Query.preload conn users (fun u -> u.id)
                posts_for_authors (fun p -> p.author_id)
                (fun u ps -> { user: u, posts: ps })
}
```

## Design notes

- **Functional, not Ecto-style mutation.** Ecto populates `%User{posts: …}` in place;
  Kraken produces a *new* combined value (`{ user, posts }`) whose shape the caller
  chooses via `combine`. No association field on the domain record.
- **has-many is the primary shape.** A belongs-to / 1:1 variant (`associate_one :
  … -> (parent -> Maybe child -> r) -> …`, taking the first matching child) is a
  trivial add if wanted; start with `associate`.
- **Nesting / multiple relations** compose by repeated `preload`/`associate` calls
  (load grandchildren, associate onto children, then onto parents) — each level its
  own query. No special machinery.
- **Where it lives:** `Kraken.Db.Query`. `associate` is pure (`needs` nothing);
  `preload` `needs {Repo}`. Uses `Std.Dict` (keys need `Eq`).

## Open questions

- Keep `preload` or ship only `associate` and let callers orchestrate explicitly?
  (`associate` is the must-have; `preload` removes `Result` boilerplate but adds API
  surface. Leaning: ship both, `associate` is the primitive.)
- `associate_one` for belongs-to now or later? (Later, unless a demo needs it.)
- Eq on `k`: `Std.Dict` needs it; fine for the common Int/Uuid/String keys.

## Build order

1. `associate` (pure) + a unit-style check (no DB needed — pure stitch).
2. `preload` (Repo) + a demo (`posts_for_authors` + `load_users_with_posts`).
3. Later: `associate_one`, and a free-standing `Db.has_many` relation value (review
   item #4-style sugar) if restating keys/predicates gets old.

## What shipped (2026-06-22) — relations declared *in the query*

The first cut (`associate`/`preload conn parents …`) worked but read awkwardly: a
6-positional `preload` call (three bare lambdas, two interchangeable `_ -> k` keys —
a silent footgun) done *outside* the query, after a manual `case Query.all …`. The
shipped design folds relation loading into the query DSL: declare the relation once,
pull it into `select!`, run it like any other query. Still separate-query under the
hood (no JSON) — only the surface changed.

### API

```saga
# define once, near the schema (both args are *column* accessors → FK named once):
authored_posts = Query.has_many posts (fun u -> u.id) (fun p -> p.author_id)

# pull it into the query as a select! field:
users_with_posts_query () = Query.query (fun () -> {
  let u = from! users
  let posts = Query.preload authored_posts u   -- Preloaded Post
  order_by! [Db.asc u.id]
  select! ({ user: u, posts: posts })          -- row: { user: User, posts: List Post }
})

# run it like anything else — one call, nested result:
Query.all conn (users_with_posts_query ())     -- List { user: User, posts: List Post }
```

### How it works (two-pass decode, separate queries)

- **`Db.Relation` / `Db.has_many`** — a parent column ↔ child column relation. Because
  it knows the child FK *column*, it **generates** the batched child query and groups
  the result; the FK is written exactly once. Accessors take anything `ToSql`
  (`Col`/`Generated`/`Sql`), so a `Generated` PK key works.
- **`Db.Preloaded child` + `Selectable (List child)`** — a `select!` field that
  contributes one column (the parent key, injected into the SELECT) and a deferred
  decode. `preload` returns it; `selection -> row` maps `Preloaded Post → List Post`.
- **Two-pass decode.** `decode_at` now threads a `RelData` and returns
  `(value, List RelKey)`. Pass 1 decodes rows with empty `RelData`, each relation slot
  emitting its parent key as a `RelKey`. The executor batches those keys, runs one
  child query per relation (`WHERE fk IN (keys)`), groups into a `Dict`, and packs a
  populated `RelData`. Pass 2 re-decodes, resolving each slot to its `List child`. One
  query per relation level — not N+1; nesting composes (the child query runs through
  the same `all`). `RelData`/`RelKey`/specs are type-erased via `kraken_unsafe`
  (`from_dynamic`/`to_dynamic`), since per-relation `k`/`child` can't be typed in a
  `Prepared`.
- **Grouping is `Dict`-grouped, O(n+m)** (`group_pairs`, foldr+prepend preserves
  order). Use the **bare builtin `Dict`** in signatures — `Dicts.Dict` misresolves to a
  phantom type (repro `/tmp/dicttest2`).

### Type-system constraints hit along the way

- A `fun`'s `where`-clause constraint head must be a single type variable — not an
  applied/anonymous/tuple type. So the child query can't generically `select!` a
  `(Col k, cols)` pair (`Generic` over an applied type is unsayable). Fix: generic-
  select `cols` alone (a single var, constraints surface fine) and pair it with the FK
  column's projection **manually** via the new `Db.project_pair` + `Db.col_projection`.
- Effects in a stored closure: storing an *effectful* function in a record field and
  calling it later miscompiled (`no evidence in scope for op …`, repro
  `/tmp/efftest2/run.saga`). Reported and **fixed compiler-side**; `RelSpec.load` /
  `RelationDef.load_children` are the ordinary effectful closures again.

### Offline verification (no Postgres)

- Parent: `SELECT t0.id AS posts, t0.id AS user_id, … FROM users AS t0 ORDER BY t0.id ASC`
  (the injected parent-key column is first).
- Child: `SELECT t0.author_id AS value, t0.id AS id, … FROM posts AS t0 WHERE t0.author_id IN ($1, …)`.
- Full stitch exercised with canned rows through a stub `Repo` on a tiny Int/String
  schema: `Acme: 2 members [Alice, Bob]` / `Globex: 1 members [Carol]` — correct key
  collection, IN params, grouping, and two-pass decode.

### Follow-ups

- `belongs_to` / 1:1 (`Preloaded (Maybe child)` taking the first match).
- Key dedup before the `IN` (parent PKs are unique, so harmless today).
- The `__rel<i>` injected-key alias is relabeled to the field name by the `Labeled`
  instance; offsets are positional so it's cosmetic, but worth a note.
