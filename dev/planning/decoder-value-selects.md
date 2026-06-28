# Decoder-Value Selects

Date: 2026-06-28

Status: spike plan. Goal is to prove out a query-result model that is fully
type-safe **without** the `Generic` trait, functional dependencies, symbol
kinds, or record synthesis — i.e. without the machinery that today powers
`deriving (Selectable …)` / `Insertable …` / `ColumnNameMap` / `InsertRow`.

This document covers the **read/select path**. Writes are sketched at the end.
Codegen/macro automation of the per-table boilerplate is explicitly **out of
scope** here — everything below is hand-written, ordinary Saga.

## Why

Typed selects are the feature we actually care about: the decoded row type is
determined by the query, not annotated by hand, and left joins turn rows into
`Maybe`. Today that determination is done by the type system:

```saga
pub trait Selectable selection row | selection -> row {
  fun to_projection : selection -> Projection row
}

pub fun project : selection -> Projection row
  where {selection: Generic selection_rep, selection_rep: Selectable row_rep, row: Generic row_rep}
```

`select`'s result type is recovered by the solver from the selection type via a
functional dependency, routed through a type-level structural representation
(`Generic`, `Leaf`/`Labeled`/`And`/`Record`, `Symbol`-kinded field names,
`KnownSymbol`). That is a large, interlocking pile of compiler features:
fundeps + coherence/improvement, symbol kinds, `where_apps`, the `Generic`
building blocks, and the `generic_fold` fusion pass that exists *only* to delete
the `Rep` trees the encoding creates at runtime.

The key realization: **none of that is needed for typed selects.** The
determination "selection → row" only needs the solver because the selection is
an *opaque value whose decode target lives in a separate, instance-related
type*. The moment the selection value *carries its own result type*, the
determination is ordinary parametric polymorphism and the fundep evaporates.

We already have that value: `Projection a`.

## Core idea: the projection *is* the selection

`Projection a` already carries everything a selection needs:

```saga
record ProjectionDef a {
  selections: List SelectItem,                  -- what goes in the SELECT list
  width: Int,                                   -- how many columns it spans
  decode_at: RelData -> Int -> Row -> Result (a, List RelSlot) DecodeError,
}
opaque type Projection a = Projection (ProjectionDef a)
```

Today `Projection a` is an *internal* type that `project` produces by walking a
column-record selection through `Generic`/`Selectable`. The redesign makes
`Projection a` the **user-facing selection**: `select` takes a `Projection a`
directly, and the row type is just `a`.

```saga
pub fun select : Projection a -> Select a
select projection = Select projection
```

`query` then needs no constraints at all — it pulls the `Projection row`
straight out of the `Select`:

```saga
pub fun query : (Unit -> Select row needs {QueryBuild}) -> Prepared row
query make = {
  let (Select projection, state) = run_query (make ())
  -- render `projection.selections` into the SELECT clause; decode via decode_at
  ...
}
```

No `Generic`, no `Selectable`, no fundep. `row` is determined by ordinary HM:
the type of the expression handed to `select`.

## The builder: `into` / `with`

`Projection` is shaped like an applicative, but **we need neither an
`Applicative` nor a `Functor` abstraction** — Saga has neither, and this design
doesn't introduce them. `into`/`with` are two ordinary top-level functions over
the single concrete type `Projection`. The only polymorphism is rank-1 `a`/`b`,
exactly like `List a` / `Result a e`. `Projection` never appears as a bare type
variable, so there is no higher-kinded anything.

```saga
pub fun into : (a -> b) -> Projection (a -> b)
into f = Projection (ProjectionDef {
  selections: [],
  width: 0,
  decode_at: fun _data _offset _row -> Ok (f, []),
})

pub fun with : Projection a -> Projection (a -> b) -> Projection b
with arg ctor = {
  let Projection ca = arg
  let Projection cf = ctor
  Projection (ProjectionDef {
    selections: List.append cf.selections ca.selections,
    width: cf.width + ca.width,
    decode_at: fun data offset row ->
      case cf.decode_at data offset row {
        Err e -> Err e
        Ok (f, reqs1) ->
          case ca.decode_at data (offset + cf.width) row {
            Err e -> Err e
            Ok (a, reqs2) -> Ok (f a, List.append reqs1 reqs2)
          }
      },
  })
}
```

Column order in the SELECT (`cf.selections <> ca.selections`) and decode
consumption order (`offset` then `offset + cf.width`) are aligned by
construction, so positional decoding is always consistent.

Leaf builders are the already-existing internals, made public:

```saga
pub fun col : Col a -> Projection a where {a: PgType}    -- was `field_projection`
pub fun expr : Sql a -> Projection a                      -- was `sql_projection`
pub fun nullable_row : Projection a -> Projection (Maybe a)   -- already public
```

(Names provisional. `col` collides conceptually with the schema-side `Db.col`
that builds a column handle inside `ColumnSet`; pick distinct names, e.g.
`read`/`read_sql`, before landing.)

## Per-table setup after the change

Per table you hand-write one decoder relating the column record to the domain
record. It is reusable across every query on that table:

```saga
record User { id: Int, name: String, age: Int }

record Users {
  id: Db.Generated Int,
  name: Db.Col String,
  age: Db.Col Int,
}   -- no deriving

fun users_row : Users -> Db.Projection User
users_row c =
  Db.into User
  |> Db.with (Db.col c.id)
  |> Db.with (Db.col c.name)
  |> Db.with (Db.col c.age)
```

`ColumnSet` and the `Db.table` value are unchanged (and `ColumnSet` was always
hand-written). So a table's setup is: domain record, column record (no derive),
`users_row`, `ColumnSet`, table value. The only net-new artifact vs. today is
`users_row` — and it replaces `deriving (Selectable User)`.

## Worked queries

Result types are inferred from the constructor handed to `into`; **no query-site
annotation, no result-type restatement.** A named result record is declared once
when the shape isn't a domain row.

Whole row:

```saga
fun adults : Db.Prepared User
adults = Db.query (fun () -> {
  let u = from! users
  where_! (Db.gt u.age 18)
  select (users_row u)
})
```

A few fields — name the result record:

```saga
record NameAge { name: String, age: Int }

fun name_ages : Db.Prepared NameAge
name_ages = Db.query (fun () -> {
  let u = from! users
  select (
    Db.into NameAge
    |> Db.with (Db.col u.name)
    |> Db.with (Db.col u.age)
  )
})
```

Inner join, mixing a whole row and a scalar (mixing still works fine — it's just
another constructor):

```saga
record UserTitle { user: User, title: String }

fun user_posts : Db.Prepared UserTitle
user_posts = Db.query (fun () -> {
  let u = from! users
  let p = inner_join! posts (fun ps -> Db.eq_col ps.author_id u.id)
  select (
    Db.into UserTitle
    |> Db.with (users_row u)
    |> Db.with (Db.col p.title)
  )
})
```

Left join → `Maybe`, the headline case, with no special handling:

```saga
record UserPost { user: User, post: Maybe Post }

fun users_with_posts : Db.Prepared UserPost
users_with_posts = Db.query (fun () -> {
  let u = from! users
  let p = left_join! posts (fun ps -> Db.eq_col ps.author_id u.id)
  select (
    Db.into UserPost
    |> Db.with (users_row u)
    |> Db.with (Db.nullable_row (posts_row p))   -- Projection (Maybe Post)
  )
})
```

`left_join!` still returns a `Nullable Posts` scope. The only change is that
turning it into a `Maybe Post` decoder is now an explicit
`nullable_row (posts_row (unwrap_cols p))` (or a small `nullable_row_of`
helper that takes the scope and the row decoder) rather than an implicit
`Selectable (Maybe out) for Nullable s` instance.

## Inference: why this is type-safe with no fundep

```saga
Db.into UserPost                              : Projection (User -> Maybe Post -> UserPost)
|> Db.with (users_row u)                      : Projection (Maybe Post -> UserPost)
|> Db.with (Db.nullable_row (posts_row p))    : Projection UserPost
select (…)                                    : Select UserPost
query (…)                                     : Prepared UserPost
```

- `into UserPost` is pinned by `UserPost`'s constructor type.
- each `with` forces its argument's element type to match the next constructor
  parameter — a wrong-typed field is a unification error at that `with`.
- the result type falls out the end; nothing restates it.

This is plain rank-1 HM. There is no "selection determines row" relation for the
solver to discharge, because the row type is literally the type parameter of the
value being selected.

## Closing the positional hole (fork)

The builder above is **positional**: `into UserPost |> with d1 |> with d2` binds
each decoder to a constructor slot by position. Two fields of the same type
supplied in the wrong order type-check and decode the wrong values — the one
place the type system won't catch a mistake even with a correct schema. This is
a real fork, not a footnote.

### The two safety properties

A projection construction has two correctness properties worth checking:

- **ordering** — each value lands in the field it was meant for.
- **completeness** — every field is supplied exactly once.

The positional builder gets completeness for free but not ordering:

| approach | ordering | completeness | needs |
| --- | --- | --- | --- |
| **positional** `into User \|> with d1 \|> with d2` | ✗ (the hole) | ✓ | nothing |
| **compiler-checked named construction** (B2 below) | ✓ | ✓ | one scoped typing rule |

Why positional is complete-for-free: `into User` seeds
`Sel (Int -> String -> Int -> User)`; each `with` peels one arrow; the result is
`Sel User` **only** when every argument is supplied (under-fill leaves a
`Sel (Int -> User)` that fails at `select`). Arity enforces completeness, but
binding is positional. Closing the ordering hole — making construction
name-keyed — is what needs help. Doing it in pure userland would require
type-level field tracking (row polymorphism / typestate), the machinery we're
escaping; the bounded compiler rule below avoids that.

### Every hole-closing option needs *some* compiler support

The fundamental operation is a **transpose**: a record *literal of decoders*
(`{ user: u }` typed `{ user: Sel User }`) is not a *decoder of a record*
(`Sel { user: User }`), and turning one into the other walks the record's fields.
That walk is not expressible in the current type system; a generic
`sequence : {l: Sel _ …} -> Sel {l: _ …}` would need row-polymorphic traversal
(HKT + row polymorphism), i.e. *more* machinery than the options below. So once
you want the hole closed, the question is never "compiler support vs none" — it's
**which flavor**.

Do not confuse the transpose with anonymous-record *type inference*
(`{a: 123} : {a: Int}`), which is ordinary, Generic-independent, and stays.
Today `select { user: u, … }` already works — but **only because the
Generic/Selectable tower *is* the transpose**: the anonymous-record `Generic` rep
(`anon_record_generic_rep` in `improve_pending_fundeps`) plus the `Selectable`
walk over `And`/`Labeled`/`Leaf`/`Record` compute both the `Projection` and the
decoded row type, with the fundep pinning it in both directions. Remove that
tower and the transpose disappears with it — keeping anonymous records buys back
the type inference, not the transpose. So B1 is not "already implemented"; it
needs the rule below to rebuild exactly what Generic was doing.

### The options

**Option A — positional builder (this document's default).** Zero compiler
involvement; ordinary `into`/`with`. Keeps the positional hole. Mitigate with a
lint or convention. Best if we want the language surface minimal and can live
with the hazard.

**Option B — name-keyed construction (closes the hole).** A compiler-understood
projection form walks a labelled literal, does the `Sel`-transpose, and **emits
the positional assembly itself in label order** — the error-prone step is
machine-generated; the human never writes positions. Surface choices:

- **B1, anonymous result:** `select { user: u, title: p.title }` ⇒
  `Projection { user: User, title: String }`. Requires keeping anonymous record
  types in the language.
- **B2, named result (recommended):** uses the **existing record-construction
  syntax**, no `=`/new tokens — `select (UserPost { user: u, post: nullable_row … })`.
  The compiler lifts each field of the *named* record `UserPost` to `Sel field`,
  resolves every label against `UserPost`'s real fields, and gets **completeness
  for free** from the record-literal rule that already requires all fields
  present. Yields nominal errors (unknown field / missing field / wrong type)
  anchored to a real type, and **needs no anonymous records**.

### B2 sub-fork: invisible vs. visible

Reusing `User { … }` verbatim means **the same syntax means two things by
context** — a normal `User` literal in most places, a lifted `Projection User`
literal inside `select`. That's invisible to the reader and tends to muddy
inference and error messages. Hence a sub-choice:

- **Invisible:** reuse `User { … }`, infer projection mode from context. Zero new
  tokens, overloaded meaning, context-sensitive typing threaded into
  record-literal checking.
- **Visible marker (leaning this way):** one explicit token, e.g.
  `select (project User { … })` (or a sigil), so "this is a lifted construction"
  is on the page. Same rule underneath, but self-announcing — the reader and the
  typechecker both know the mode, and errors can say "in a projection literal,
  fields must be `Sel _`."

A tiny bit of *new* syntax (a marker) is likely preferable to "no new syntax but
context-dependent meaning."

### None of this is the old tower

Every Option B variant reintroduces **none** of what we're deleting: it's a
typing+lowering rule, not a fundep (no solver), it walks a *source literal* not a
type-level `Generic` rep, and labels are concrete strings (no `Symbol` kinds, no
`KnownSymbol`). It is one non-viral rule, scoped to the projection form, that
cannot generalize itself into a type-system feature. This is the whole reason it
feels dramatically simpler than generics/fundeps — it is structurally a much
smaller, contained thing.

### Recommendation

Build the spike on **A** — it proves the `Projection`-value core needs nothing
from the compiler. If the positional hazard bites in practice, add **B2 with a
visible marker**: it closes the only in-language safety hole at the cost of one
bounded, projection-scoped typing rule, reuses existing record syntax, gets
completeness for free, and keeps result types nominal (so anonymous records can
still be dropped). B1 only wins if ad-hoc anonymous projections are valued enough
to keep anon records as a language feature. The DB-schema correspondence remains
an unverifiable trust boundary under every option, so B is about closing the
*last in-language* gap, not total safety.

## Expression operands without `ToSql`

The select path above removes the `Selectable` fundep, but `ToSql` /
`ToArraySql` / `ToJsonbSql` are also fundep traits (`input -> a`) and are the
*other* thing keeping the solver alive. They turn out to be removable by the
same move — collapse the operand types — and removing them is what takes
fundeps to **zero consumers**.

What `ToSql` actually abstracts over is tiny. The only impls are:

```saga
impl ToSql a for Col a       where {a: PgType} { ... }   -- a column is an operand
impl ToSql a for Generated a where {a: PgType} { ... }   -- so is a generated column
impl ToSql a for Sql a                         { ... }   -- and an expression is itself
```

i.e. `ToSql input a` means "input is, or trivially becomes, a `Sql a`
expression," and the fundep exists only to pin the element type `a` from the
operand so the *other* side can be checked against it. A column is just a leaf
SQL expression; the `Col`/`Sql` split on the read side was always artificial,
and only the fundep made it tolerable.

**The fix: make read/expression operands uniformly `Sql a`.** `from!` / joins
return a column record whose fields are `Sql a` (a column reference is a `Sql a`
carrying its `PgType` decoder — the representation `sql_projection` already reads
from). Then every operator is an ordinary single-parameter-bounded function:

```saga
pub fun eq     : Sql a -> a     -> Expr where {a: PgType}   -- operand vs literal
pub fun eq_col : Sql a -> Sql a -> Expr where {a: PgType}   -- operand vs operand
pub fun add    : Sql a -> a     -> Sql a where {a: PgType}
pub fun lower  : Sql String -> Sql String
-- arrays/jsonb similarly take Sql (Array a) / Sql (Jsonb a) directly
```

**Literal ergonomics are preserved.** `eq`/`gt`/… already take the RHS as a raw
`a`, not a wrapped value, so:

```saga
where_! (Db.eq u.age 18)        -- u.age : Sql Int  ⇒  a = Int  (plain unification)
where_! (Db.gt (Db.add u.age 1) 18)   -- expression LHS works the same
```

The element type `a` is fixed by unifying the operand's `Sql a` with its
concrete type — no fundep, no `ToSql`. A standalone literal *expression* (e.g.
`coalesce`, `select (Db.lit 5)`) still wraps via `Db.lit : a -> Sql a where {a:
PgType}`, but comparisons against a literal do not.

This deletes `ToSql` / `ToArraySql` / `ToJsonbSql`, all their impls, and their
fundep usage. Combined with the select-path removal of `Selectable`, **no trait
declares a fundep anymore**, so the solver loses its last consumer.

**Sub-question (write-side column identity).** `Col a` / `Generated a` can't
disappear entirely: writes (`assign`, insert targets, `primary_key`) need a
column's *name*, not just an expression. Options: keep `Col`/`Generated` as
schema/write-only types and have `from!` project them to `Sql a` for the
read/expression view; or carry the column name inside the `Sql a` leaf and
recover it for writes. This is a write-side design detail (see below) — the read
spike only needs "operands are `Sql a`," which is satisfied either way. Note the
RHS-as-raw-`a` operators mean `from!` returning `Sql a` fields is enough to keep
predicates ceremony-free.

## Writes

The write side is where it *feels* like the most machinery (`Insertable`
synthesizes a whole record type, `InsertRow` and `ColumnNameMap` are routed
derives). But it collapses to the same shape as the read side: a single
hand-written **value per table that carries its types**, replacing the
fundep-linked trait cluster.

### What the three write traits actually do

```saga
trait InsertRow a      { fun insert_row : a -> List (String, Value) }       -- encode insert record → (label, value)
trait ColumnNameMap a  { fun column_name_map_rep : a -> List (String, String) }  -- column record → (label, sql_name)
trait Insertable cols ins | cols -> ins synthesizes via InsertField …       -- fundep link + record synthesis
```

`insert` glues them: `insert_row value` gives `(label, value)` pairs, `column_name_map cols`
gives `label → sql_name`, and `insert_pairs` joins them by label into
`(sql_name, value)`. `Insertable` is a method-less fundep link whose only job is
to let `insert : Table cols -> ins -> …` recover `ins` from `cols`, plus it
triggers the synthesis of `UsersInsert`. So: one derive synthesizes a type, two
derives do structural walks, and a fundep ties it together — to produce a list
of `(sql_name, value)` pairs.

### The replacement: a `Writer` value

The label→name join only exists because `insert_row` (from the *synthesized*
record) speaks Saga labels while SQL names live in `ColumnSet`. Hand-write the
encoder and that indirection vanishes — the writer reads SQL names directly off
the column handles (which already carry their `ColumnInfo`):

```saga
opaque type Writer cols ins = Writer (cols -> ins -> List InsertCell)
type InsertCell = Bind String Value | Skip   -- Skip = omitted (a Writable Auto)

pub fun writer : (cols -> ins -> List InsertCell) -> Writer cols ins
pub fun set   : Sql a -> a          -> InsertCell where {a: PgType}  -- always binds; name from the column leaf
pub fun set_w : Sql a -> Writable a -> InsertCell where {a: PgType}  -- Auto → Skip, Provide v → Bind
```

Per table — hand-write the insert record (the only "synthesis" replacement, ~3
lines) and the writer (~5 lines), mirroring `users_row`:

```saga
record UsersInsert { id: Db.Writable Int, name: String, age: Int }

fun users_writer : Db.Writer Users UsersInsert
users_writer = Db.writer (fun c r -> [
  Db.set_w c.id   r.id,     -- generated column: Db.auto omits, Db.provide binds
  Db.set   c.name r.name,
  Db.set   c.age  r.age,
])
```

`insert` and friends drop *all three* trait constraints and take the writer; the
types are pinned by the `Writer cols ins` value, exactly as the row type was
pinned by `Projection row`:

```saga
pub fun insert : Table cols -> Writer cols ins -> ins -> Prepared Unit
insert table_value w value = {
  let cols  = insert_cols table_value          -- ColumnSet, unaliased (INSERT has no table alias)
  let cells = run_writer w cols value
  finish (insert_parts table_value (bound_cells cells))   -- drop Skips, keep (sql_name, value)
}
```

No fundep (the writer carries `cols` and `ins`), no `Generic` (encoding is the
writer body), no `ColumnNameMap` (names come from the column leaves), no
`InsertRow`/`Insertable`. `insert_all`, `upsert`, `insert_on_conflict_*`, and
the `_returning` variants take the same `Writer` argument; the `_returning`
projection callback returns a `Projection row` like any other select.

### `update_all`, plain `update`/`delete`

- **`update_all`** (whole-row save) uses a domain-record writer
  `Writer cols User` plus `ColumnSet.primary_key`: encode all cells, partition by
  the key columns, emit `SET` for the rest and `WHERE` for the key. Same `Writer`
  mechanism, domain record instead of insert record. (A table that uses both
  `insert` and `update_all` writes two small writers; most write only the insert
  one.)
- **Plain `update` / `delete`** are *already* derive-free — they use `set!` /
  `where_!` on column handles via the `Update` effect, no `Insertable`/`InsertRow`.
  Only their `_returning` variants currently carry `Generic`/`Selectable`, which
  the read redesign already removes (the projection callback returns
  `Projection row`).

### Column identity (resolves the earlier sub-question)

This pins down the `Col`/`Sql` question left open under "Expression operands":
the column record's fields are uniform `Sql a` that carry a column-origin marker
in the leaf. Reads project them (`users_row` via `read`/`sql_projection`),
predicates use them as operands (no `ToSql`), and `set`/`set_w`/`Db.ref`/`Db.key`
recover the SQL name from the leaf. Consequently **`Col a` and `Generated a` as
distinct column-record field types are no longer needed** — `Generated`'s only
purpose was telling synthesis to emit a `Writable` field, and the hand-written
insert record now declares `Writable a` directly. `Writable` itself stays (a
plain `Auto | Provide a` ADT with `Db.auto` / `Db.provide`). The only knob left:
if keeping `Col`/`Generated` as documentation markers is preferred, they become
transparent aliases coerced to `Sql a` in `users_row` — at the cost of a second
field-type form on the read path.

### Symmetry

The whole per-table schema becomes symmetric and fully hand-written, no derives:

| Direction | Artifact | Type |
| --- | --- | --- |
| read | `users_row` | `Users -> Projection User` |
| write (insert) | `UsersInsert` + `users_writer` | `Writer Users UsersInsert` |
| write (save) | `users_save_writer` (if used) | `Writer Users User` |
| names/PK | `ColumnSet` impl | (already hand-written) |

That is the "bunch of work" from before — but reframed: the *machinery* (record
synthesis, two routed derives, a fundep link) is deleted, and what remains is a
handful of obvious per-table functions structurally identical to the read
decoder.

## What gets deleted

Kraken (`lib/Core.saga`, `lib/Write.saga`):

- `trait Selectable selection row | selection -> row` and all its
  `Generic`-routing impls (`Selectable … for Leaf/Labeled/And/Record/…`).
- `project`, the `Generic`-constrained `selection_items`, and the
  `Generic`/`Selectable` constraints on `query`, `from_subquery`, the
  full-join builder, etc.
- `ToSql` / `ToArraySql` / `ToJsonbSql` and their impls (operands become
  `Sql a`; see "Expression operands without `ToSql`").
- The write-side derives and their traits: `Insertable` (+ `synthesizes via`
  record synthesis), `InsertField`/`InsertFields`, `InsertRow`, `ColumnNameMap`/
  `ColumnNameFields`, `column_name_map` — all replaced by a per-table `Writer`
  value (see "Writes"). `Writable` (the `Auto | Provide` ADT) stays.
- `Col a` / `Generated a` as distinct column-record field types (fields become
  uniform `Sql a` with leaf-level column identity); `Generated`'s role moves into
  the hand-written insert record's `Writable a` fields.
- `KnownSymbol`/`Proxy` usage.

Compiler (`saga`), once kraken and saga_json no longer use it:

- `src/stdlib/Generic.saga` and the prelude auto-import.
- `src/codegen/generic_fold/` (the entire fusion pass — it only exists to
  cancel `Rep` trees).
- functional-dependency solving — *all* of it, not just trimmed
  (`FUNCTIONAL_TRAITS`, the `| a -> r` syntax, `TraitFundep`,
  `improve_pending_fundeps`, the call-site coherence fallback,
  `fundep_determined_vars`). Once `Selectable` and `ToSql` are gone, no trait
  declares a fundep, so the solver has zero consumers. The solver is also
  currently *entangled* with `Generic` (`improve_pending_fundeps` special-cases
  `is_generic_trait_name` for the anonymous-record rep); removing `Generic`
  removes those branches too.
- `Symbol` kinds / `KnownSymbol`.
- record synthesis (`synthesizes` clause, field-map traits).
- `where_apps` (free type vars in impl where-clauses), if nothing else needs it.

Multi-parameter traits *without* fundeps can stay if wanted; only the
determination machinery is being removed.

## Open questions / wrinkles

1. **Positional ordering footgun** — see "Closing the positional hole (fork)".
   Option A (positional builder) keeps it; Option B2 (named-record construction
   form) closes it with one bounded `select` rule and no anonymous records.
   Decision deferred until the spike shows whether the hazard bites in practice.

2. **`select u` bare-column-record sugar is gone.** You now write
   `select (users_row u)`. This is the deliberate trade: the sugar is the only
   thing that wanted type-directed `cols → row` resolution. If it turns out to
   matter, it can be re-added later via a *narrow* concrete-self lookup
   (associated-type-for-concrete-heads), independent of the rest of the tower —
   but the spike assumes we live without it.

3. **`ToSql` / `ToArraySql` / `ToJsonbSql`** — resolved (see "Expression
   operands without `ToSql`"): collapse read/expression operands to `Sql a` and
   the fundep disappears with literal ergonomics intact. Write-side column
   *identity* (`set`/`assign`/insert targets need a column name) is resolved
   under "Writes → Column identity": names are carried in the `Sql a` leaf and
   read back by the write builders.

4. **Derived tables / subqueries.** `from_subquery` currently uses
   `selection_items` (Generic) to render the inner SELECT without the row type.
   With `Projection`-as-selection this gets *simpler*:
   `selection_items proj = projection_selections proj` — the projection already
   carries its `selections`. The label→derived-column mapping
   (`derived_columns`) needs to read labels from the projection instead of the
   Generic rep; mechanical but needs a concrete plan.

5. **Preloads.** `Preloaded out` already decodes via `decode_at` + `RelData` and
   carries its own `out`. It should slot into the builder as just another
   `Projection`-shaped leaf (`select (into Ctor |> with (users_row u) |> with
   (preload authored_posts u))`). Confirm `make_preloaded` produces something
   `with`-composable.

## Spike scope

Minimum to validate the model on the read path:

1. Add `into` / `with`; make `col` (`field_projection`), `expr`
   (`sql_projection`), and `nullable_row` public.
2. Change `select` to take `Projection a`; drop the `Generic`/`Selectable`
   constraints on `query` (leave the other builders on the old path for now).
3. Port one table (`users` + `posts`) to hand-written `users_row` / `posts_row`,
   delete their `deriving (Selectable …)`.
4. Reproduce: whole-row select, few-field select with a named record, inner join
   with mixed row+scalar, left join → `Maybe`. Confirm all infer with no
   query-site annotation and decode correctly end-to-end.
5. Only then tackle writes, the `ToSql` → `Sql a` operand merge, and the
   subquery/preload ports.

The two fundep removals are **independent and can be sequenced**: the select
path (steps 1–4) only touches `Selectable`, and the existing `ToSql`-based
operators keep working unchanged during the spike (predicates like
`where_! (Db.eq u.age 18)` are unaffected). The operand merge is a separate
follow-up. The fundep *solver* can only be deleted after **both** `Selectable`
and `ToSql` are gone — sequence the solver deletion last.

If step 4 holds, typed selects are confirmed to need nothing from the type
system beyond rank-1 parametric polymorphism, and the deletion list above
becomes a mechanical follow-up.
