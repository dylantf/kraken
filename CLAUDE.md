# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Kraken is a typed, composable PostgreSQL query builder written in **Saga**, a
statically-typed functional language that compiles to Core Erlang / BEAM. The
library lets you build SQL with full type inference of result-row shapes,
including nullability that falls out of join kind. It is not an ORM; raw SQL
stays available as an escape hatch at every layer.

Saga itself lives outside this repo (compiler at `~/.saga/bin/saga` on PATH,
`github:dylantf/saga`). This repo is the Kraken library plus a small demo app.

## Commands

The `saga` CLI drives everything (run from the repo root in project mode):

- `saga check` — typecheck the whole project without building. **This is the
  fast inner-loop command; use it to validate changes.**
- `saga build` — compile to BEAM under `_build/dev/`.
- `saga run` — build and run the binary (`src/Main.saga`). **Requires a running
  PostgreSQL** (see below); the demo connects on start.
- `saga test [FILTER]` — run tests (FILTER is a path or substring).
- `saga emit` — print generated Core Erlang to stdout (useful when debugging
  codegen or the Erlang FFI boundary).
- `saga fmt <FILE>` — format a single source file.
- `saga check <FILE>` / `saga run <FILE>` — single-file mode for quick experiments.

There is no Makefile or wrapper script — invoke `saga` directly. The Nix flake
(`flake.nix`, `.envrc` with `use flake`) provides `erlang` + `rebar3` for the
dev shell; it does not yet vendor the saga compiler itself (commented out). This
gives bleeding edge development compiler builds.

### Running the demo

`src/Main.saga` connects to a local Postgres database named `kraken_testing`
(user/password `postgres`, port 5432) and prints rendered SQL plus live query
results. You need that database reachable for `saga run` to succeed.

## Architecture

### Module layout

- `lib/Kraken/Db.saga` — **the vocabulary** (imported as `Db`). The largest and
  most important module: the `PgType` trait, `Col`/`Table`/`Nullable`/`Array`/
  `Jsonb` types, the typed-SQL expression layer (`Sql a`, `Expr`, `SqlFrag`),
  `Selectable`/`Projection`, and all predicate / ordering / grouping / aggregate
  helpers.
- `lib/Kraken/Db/Query.saga` — the `QueryBuild` effect (the `from!`/`join!`/
  `select!` DSL), SQL rendering, the `Prepared` type, the `Repo` effect + the
  `pg_repo` handler, and execution (`all`/`one`/`run`/`into`).
- `lib/Kraken/Db/Dml.saga` — writes: `update`, `delete`, `exec` (non-returning,
  returns affected-row count). Parallel to `Query`, reusing the `Db` vocabulary.
- `lib/kraken_unsafe.erl` — tiny Erlang FFI: `from_dynamic` (unsafe cast) and
  `slice_all_null` (the all-NULL sentinel that decides `Just`/`Nothing` for a
  left-joined row).
- `src/Main.saga`, `src/Read.saga`, `src/Write.saga` — the demo app. `Read.saga`
  is also the canonical **example of how to declare a schema** (domain record +
  column record + `ColumnSet` impl + table value).

`project.toml` declares the binary (`src/Main.saga`), the exposed library modules
(`Kraken.Db`, `Kraken.Db.Query`, `Kraken.Db.Dml`), and path deps `saga_pgo`
(Postgres driver wrapping `pgo`) and `saga_json`. `saga.lock` pins transitive hex
deps. `dev/planning/sql-coverage-and-query-expressivity.md` is the authoritative
design doc and roadmap — **read it before extending the SQL surface.**

### Core type model (read this before editing the query layer)

Everything funnels through a few opaque types:

- `SqlFrag` — a list of `SqlPart` (`Text String | Param Value`). The universal
  building block; rendering walks these and turns `Param`s into `$1`, `$2`, …
- `Sql a` — a fragment **plus a decoder** for the value it produces. This is the
  single abstraction for any typed SQL value: columns, aggregates, raw
  expressions, casts. Aliasing comes from anonymous-record labels at the select
  site, not from the `Sql` itself.
- `Expr` — a boolean fragment (predicates: `eq`, `gt`, `in_`, `and_`, …).
- `Projection a` — selections + a width + a positional `decode_at` that turns one
  result row into an `a`. Built generically from a selection value.

The selection→row inference is the heart of the library. `select!` takes an
anonymous record/value; `Selectable` instances over the Generic representation
(`Leaf`/`Labeled`/`And`/`Record`) walk it to build a `Projection`, and the row
type is inferred from the selection's shape. There is **no per-table select
boilerplate** beyond the `deriving (Db.Selectable Domain)` on the column record.

### Nullability model (the library's north star)

Nullability comes from **exactly two places: the schema and the join kind.**

- Columns are uniform `Db.Col a`. A schema-nullable column is just `Db.Col (Maybe a)`.
- `from!` / `inner_join!` hand back the plain column record; `left_join!` returns
  a `Db.Nullable cols` scope. Selecting a `Nullable` scope infers `Maybe row`
  via one generic instance + the all-NULL sentinel (`slice_all_null` in
  `kraken_unsafe.erl`) — no per-table optional impl, no query-site annotation.
- Trade-off: you cannot dot-select an individual nullable scalar off a left join.
  Select the whole `Maybe Post` instead. To reference a left-joined table's
  columns in post-join predicates/ordering (e.g. the anti-join
  `where_! (Db.is_null (Db.unwrap_cols p).id)`), use `Db.unwrap_cols` — but
  **never in `select!`** (it drops nullability and fails at decode time).

### Effects

Kraken uses Saga's algebraic effects:

- `QueryBuild` — the query DSL. Its operations are invoked with `!` syntax inside
  the closure passed to `Query.query`. The `collect_query` handler threads a
  `QueryState` through a continuation-passing `QueryStep`.
- `Repo` — the execute capability. `pg_repo` is the production handler (runs
  against `Postgres`); provide your own in tests. Wired at the call boundary with
  `... with Query.pg_repo` (see `Main.saga`).
- Transactions reuse saga_pgo's `Postgres` + `Transaction` effects directly.
  `Query.transaction conn body` wraps `SagaPgo.transaction`: it provides `pg_repo`
  *inside* the body (so the body uses the full `Repo` API — `all`/`one`/`exec`/the
  DML helpers — and they auto-join the tx via pgo's process dictionary), commits on
  `Ok`, rolls back on `Err`. So a transaction needs `{Postgres, Transaction}` at the
  boundary (wire `with {pg_transaction, pg, ...}`), not `Repo`.

### Schema declaration pattern

To add a table (see `src/Read.saga` for the worked example), you write four things:

1. a domain record (`User`) — the decoded row type;
2. a column record (`Users`) with `Db.Col`-typed fields, `deriving (Db.Selectable User)`;
3. an `impl Db.ColumnSet for Users` mapping fields to SQL column names;
4. a table value: `users = Db.table "users"`.

The `ColumnSet` impl is the remaining hand-written boilerplate (a candidate for a
future derive, but that needs compiler support).

## When writing Saga:

- **`(List.append …)` fails to parse** — `List` is also a type, so a
  parenthesized qualified call is read as a qualified type. Bind an intermediate
  `let` instead.
- Saga has no significant whitespace; automatic semicolon insertion. Therefore,
  **multi-line function application with args on following lines** leaves the
  function unapplied. Keep application on one line or use `let` bindings, or piping.
- The Erlang FFI uses `@external("erlang", "module", "fun")` annotations; the
  hand-written bridge modules (`kraken_unsafe`, `saga_pgo_bridge`) live in
  Erlang. pgo represents SQL `NULL` as the atom `null`.
- **Trait methods can't be imported by name** (e.g. `encode_pg`); import the trait
  and the method comes with it, or expose a plain `pub fun` wrapper.
- **Single-param trait impls need `for`**: `impl EncodeLeaf for Leaf a where {…}`.
- **A covariant `deriving`-routed bridge can't build a contravariant encoder** —
  the applied functional-bridge derive only emits `map from` over the wrapper
  (good for `Selectable`/`Projection`, which *produces* a row; not for an encoder
  that *consumes* one). Encode by folding the domain record's Generic rep via a
  derivable single-param trait (`InsertRow`), mirroring saga_json's `ToJson`.
- **`fun u -> u.field` can report "ambiguous field"** when the column-record type
  isn't pinned and `field` also exists on other in-scope records (e.g. the domain
  + synthesized insert records). It bites a callback whose `cols` type is inferred
  late — notably a DML op taking *two* column-record callbacks (a conflict target
  + a projection). Lambda param annotations don't parse and a typed `let` flows too
  late. Workaround: use a whole-row projection (`fun u -> u`), which pins `cols`.
- **`with {…}` handler order: a dependent handler must be listed before the one it
  needs.** `pg_transaction needs {Postgres}`, so the boundary is
  `with {pg_transaction, pg, console}` — listing `pg` first leaves `Postgres`
  unhandled and `main` errors with "entry point … cannot use `needs`".

## Status

Kraken has a well-rounded **read** path (selects, inner/left joins, where/group/
having/order/limit/offset, aggregates, arrays, JSONB, raw-SQL escapes) and a
**write** path in `Kraken.Db.Dml`: `insert` (the insert-shape record is
**synthesized** from the schema by `deriving (Db.Insertable <Name>)` — the
compiler's generic `synthesizes via <FieldMap> deriving (...)` trait mechanism,
driven by Kraken's `InsertField` rewrite map: `Col a → a`, `Generated a →
Writable a` — and `deriving (Db.InsertRow)` is attached for encoding), `update`
(partial, `set!`/`where_!`), `update_all` (whole-entity save keyed by
`primary_key`, with the accepted entity type tied to the table via the read
path's `Selectable cols row | cols -> row` link), `delete`, and `exec`
(affected-row count). `insert`/`update`/`delete` each have a `*_returning`
variant: they take a projection callback over the table's columns (like
`select!`), append `RETURNING`, and yield a `Prepared row` runnable with
`Query.all`/`Query.one` — reusing the read path's `Selectable`/`Projection`
decode. Upserts are covered by `insert_on_conflict_do_nothing` and `upsert`
(`ON CONFLICT (<target>) DO UPDATE SET … = EXCLUDED.…`), with conflict targets
named type-safely via `Db.ref`; both have `*_returning` variants that append
`RETURNING` and decode through the projection. Schema columns the DB fills are marked
`Db.Generated a` (reads like a column, unsettable via `set!`). **Transactions**
(Tier 8) are done: `Query.transaction conn body` runs a `body :
Unit -> Result a DbError needs {Repo}` atomically — committing on `Ok`, rolling
back on `Err` — as a thin wrapper over `SagaPgo.transaction` (no direct Erlang
bridging). The body uses the ordinary Kraken `Repo` API; the only impedance is the
error channel — saga_pgo's rollback path is `QueryError`-typed, so a `QueryFailed`
round-trips losslessly while a `DecodeFailed` (a row that came back but didn't
decode) rolls back with its message preserved. The roadmap's remaining items are
smaller (DO UPDATE column subsets / arbitrary expressions like
`count = users.count + 1`, `ON CONSTRAINT` conflict targets). When extending SQL
coverage, prefer growing the typed `Sql a` expression model over adding one-off
APIs.
