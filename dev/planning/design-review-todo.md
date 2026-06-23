# Design Review — Ordered TODO

Date: 2026-06-21

A prioritized worklist coming out of a design/ergonomics review of the library.
Ordered so we can knock them out one at a time, top to bottom. Each item notes
the problem, the fix, and the relevant code locations.

The review's headline: the core design is strong (nullability-from-schema+join,
`Sql a` as the universal fragment+decoder, deferred `$n` numbering, effects over a
builder monad, full-join-as-its-own-constructor). These items are about closing
the gaps, not reworking the foundation.

---

## 1. Close the soundness lies

The places where the type says one thing and runtime can disagree — highest
priority, because they undercut the whole value proposition of a typed builder.

### 1a. `scalar_subquery` types an empty result as non-null — DONE (2026-06-21)

- **Problem:** `scalar_subquery` returns `Sql a`, but an empty subquery yields SQL
  NULL → decode failure at runtime. Docs say "remember to `coalesce`," but
  "remember or it crashes" is what the types should eliminate.
- **Fix:** add `scalar_subquery_maybe : ... -> Sql (Maybe a)` as the safe default;
  keep the non-null variant for deliberate use (after `limit! 1` on a
  guaranteed-present row, or an aggregate that always returns a row).
- **Where:** `lib/Kraken/Db/Query.saga` (`scalar_subquery` / `scalar_subquery_maybe`,
  sharing a new `scalar_subquery_frag` helper).
- **Done:** added `scalar_subquery_maybe`, factored the shared fragment builder,
  rewrote the `scalar_subquery` doc to mark the non-null soundness boundary. Demo:
  `users_with_a_post_title_query` in `src/Read.saga`. `saga check` green.

### 1b. `insert_all` panics on a runtime-empty list — DONE (2026-06-21)

- **Problem:** an empty batch is *data*, not programmer error (real call sites
  guard `[]`). Panicking on a runtime value — silent until production if the guard
  is forgotten — is the sharpest edge in the library.
- **Fix (chosen):** a `noop: Bool` flag on `Prepared`. `insert_all` /
  `insert_all_returning` return `noop_prepared` for `[]`; `exec` short-circuits to
  `Ok 0`, `all` to `Ok []` (so `one` → `Ok Nothing`, `exactly_one` →
  `ExpectedOneRow 0`), all without a database round trip. No call-site guard needed.
  This keeps the build/execute split clean — the flag is part of the built artifact
  describing what to execute.
- **Where:** `Prepared` + `noop_prepared` + `all` in `lib/Kraken/Db/Query.saga`;
  `exec` + the two `insert_all*` guards in `lib/Kraken/Db/Dml.saga`. The
  `insert_all_parts_of` panic is now an unreachable defensive backstop.
- **Done:** `saga check` green. Not yet exercised against a live DB.

> The other panics (two `from!`, conflict-covers-all-columns, `update_all` on
> `NoKey`) are genuine programmer errors — leave them as panics.

---

## 2. Fix the O(n²) append patterns — DONE (2026-06-21)

Pervasive and cheap to fix now while the surface is small; annoying to retrofit
once large `IN` lists / wide bulk inserts appear.

- **Problem:** rendering snocs onto a growing list per part, and the DML renderer
  does `acc.sql <> text` per part; `QueryState` snocs each clause too.
- **What was actually O(n²) (scales with *data* — big `IN` lists, bulk inserts):**
  - `render_text`/`render_frag` — `List.append state.parts [...]` snoc onto the
    growing accumulator.
  - DML `render_parts` — `acc.sql <> text` per part.
  - `number_parts` — right-recursive `text <> sql` re-copied the growing suffix.
- **What only *looked* it (left as-is):** `append_frag`/`append_frags` in `Db.saga`
  are right-nested with small left operands, and `lists:append(Xs,Ys)` is O(|Xs|),
  so they're linear. The effect-op clause accumulators (`List.append state.wheres
  [expr]`) are O(clauses²) but clauses are hand-written and always tiny — not a
  data-scaling risk. Noted, not changed.
- **Fix (chosen):** accumulate the parts list reversed (O(1) cons) and reverse once
  at extraction (mirrors saga_json's reversed-iolist renderer). `number_parts`
  became a single left fold building reversed text pieces + params, then
  `String.join "" (reverse …)` once — O(n). Made `number_parts` `pub` and routed the
  DML layer through it, deleting DML's duplicated `Rendered`/`render_parts`.
- **Verified:** golden diff of 17 representative rendered queries (selects, joins,
  subqueries, CTE, full join, window, CASE/CONCAT, arithmetic, INSERT) — byte
  identical before/after via a clean worktree at the prior commit.

---

## BUG (discovered during #2 verification) — `insert_all` crashes at runtime — FIXED (compiler-side, 2026-06-21)

**Pre-existing, not from this review's work.** Surfaced when the golden-diff harness
ran the demo's bulk insert. Confirmed on current `main` (clean build). Root cause and
fix are at the end of this section.

- **Symptom:** `saga run` of the demo crashes at the bulk-insert line:
  ```
  Runtime error: bad argument
    read:__dict_Kraken_Db_InsertRow_read_Read_UsersInsert
    kraken_db_dml:insert_pairs/4
    kraken_db_dml:insert_all_parts_of (lib/Kraken/Db/Dml.saga:310)
    write:insert_users_query
  ```
  The top frame is the *derived `InsertRow` dict for the synthesized `UsersInsert`*
  being invoked with a bad argument.
- **Impact:** `insert_all` / `insert_all_returning` are unusable at runtime for the
  synthesized insert types, despite typechecking and being marked "done". Single-row
  `Dml.insert` works.

### Investigation (2026-06-21) — narrowed, not yet root-caused

What the bug is **NOT** (each ruled out empirically):

- **Not the `List.map` closure.** Replacing
  `List.map (fun v -> insert_pairs table_value v) values` with a plain recursive
  helper (`insert_pairs_each`) crashes *identically* (`insert_pairs_each/4 →
  insert_pairs/4 → __dict_…UsersInsert`). So it is not a closure-capture issue.
- **The difference is hop count to a fundep-determined synthesized type.** Single
  `insert` is 1 hop (`insert → insert_pairs`) and works; bulk is a chain
  (`insert_all → insert_all_parts_of → insert_pairs`) where `ins` is fixed by the
  `Insertable cols ins | cols -> ins` fundep and its `InsertRow` dict is threaded
  through several constrained functions before `insert_row` is finally called.

**Could not reproduce in a fresh cross-module project** (`/tmp/dicttest`) despite
faithfully mirroring, in combination:
custom routed `Generic` derive (trait + `Record`/`And`/`Labeled`/`Leaf` rep
instances + inner per-type leaf trait), `synthesizes via <FieldMap> deriving (…)`
with a `cols -> ins` fundep, a phantom-`cols` `Table`-like handle, **two** actively
used dicts in the helper (a `ColumnSet`/`ColumnNameMap` analog on `cols` + the
routed trait on `ins`), the exact multi-hop constrained chain (with *and* without
`List.map`), and a coexisting hand-derived instance of the same trait in the module.
Every combination ran correctly. So the trigger depends on something specific to
Kraken's real types that doesn't survive extraction — prime suspects: the `Writable
a` ADT as the `Generated a → Writable a` field-map result (vs a plain `Maybe`), the
trio of derives on `Users` (`Selectable User` + `Insertable UsersInsert` +
`ColumnNameMap`), or the empty-bodied `Insertable` synthesize interacting with the
`Selectable` fundep that shares the same `cols`.

### ROOT CAUSE — FIXED (2026-06-21, compiler-side)

**It was never a dict-passing bug.** The `InsertRow` dict was threaded correctly. The
crash was a **codegen bug that dropped the record literals' fields**: the three
`UsersInsert { id: Db.auto, name: …, age: … }` rows in the bulk-insert list were
lowered to bare `{'read_UsersInsert'}` tuples with *no fields* (vs the single-insert
path's correct `{'read_UsersInsert', auto, "Carol", 31}`). The `InsertRow` method then
did `element(2, row)` on a fieldless tuple → `bad argument`. That `element` lives
lexically inside the synthesized dict builder `__dict_…InsertRow_…UsersInsert/1`, which
is why the crash *frame* pointed at the dict — a red herring that sent the whole
investigation down the dict-passing path.

Why the fields were dropped:

- A `RecordCreate` lowers to a tagged tuple. The **tag** is resolved by name
  (`mangle_ctor_atom` via `constructor_atoms`) — robust. The **field order** (which
  value goes in which tuple slot) was resolved by **NodeId / current-module name**
  (`resolved_record_fields` → `current_record_type_name`) — fragile.
- `Dml.insert_all` gets **inlined** into `Write` (single `insert` stays a remote call).
  Inlining a function with a non-duplicable argument freshens that argument's NodeIds
  (`bind_subpats` → `freshen_expr_ids`). The list arg is non-duplicable because the
  `id: Db.auto` field lowers to a call, not a constant. Freshening orphaned each
  record node from `Write`'s front-resolution `record_type(node)` map.
- The synthesized layout *was* registered — under `Read.UsersInsert` — but the records
  are lowered in module `Write`, so the only name fallbacks tried were `UsersInsert`
  and `Write.UsersInsert`; both miss. `resolved_record_fields` then returned `None` and
  the lowering's `unwrap_or_default()` silently produced an **empty field order** →
  fieldless tuple → runtime crash.

This is exactly why `/tmp/dicttest` never reproduced: the trigger isn't the dict chain
at all — it's a cross-module record literal whose type is defined in *another* module
(`Read.UsersInsert`), lowered inside a *third* module (`Write`), through an *inlined*
generic function. The fundep/synthesize/derive machinery was a coincidence of the setup.

**Fix (in the saga compiler, `~/projects/saga`):**
1. `src/codegen/lower/semantic.rs` — `resolved_record_fields` now has a final,
   name-based fallback (`record_fields_by_unique_suffix`): resolve the field layout by
   the constructor's bare surface name when it uniquely matches one `<module>.<Name>`
   across all registered records. Mirrors how the constructor *tag* already resolves by
   name, so layout resolution survives NodeId freshening and cross-module inlining.
   Ambiguous names fall through (no wrong-layout guess).
2. `src/codegen/lower/exprs/dispatch.rs` — replaced the silent `unwrap_or_default()` in
   `RecordCreate` lowering with a hard compile-time panic. A field layout that can't be
   resolved is a compiler bug; emitting a fieldless tuple turned it into a latent
   runtime `bad argument`. Now it fails loudly at build time (the "no silent footguns"
   property, applied to the compiler itself).

**Verified:** `cargo test` green (1111 + 160 + 115 + 70 …); `cargo clippy` clean.
`saga run` of this repo now prints
`INSERT INTO users (name, age) VALUES ($1, $2), ($3, $4), ($5, $6)` and
`insert_all_returning` renders `… RETURNING users.id`. Item **1b** is genuinely done
now (rendering verified; still not exercised against a live DB).

---

## 3. Ship `DISTINCT` / `DISTINCT ON` — DONE (2026-06-21)

- **Problem:** still listed as near-term Tier 1 and not done; one of the genuinely
  common missing things. `count_distinct` doesn't cover row-level distinct.
- **Fix:** `distinct!` (`SELECT DISTINCT`) and `DISTINCT ON (...)`; thread through
  `QueryState` and render after `SELECT`.
- **Done:** added a `DistinctKind` (`NoDistinct | DistinctAll | DistinctOn (List
  Group)`) field on `QueryState`; two new `QueryBuild` ops — `distinct! ()` (plain)
  and `distinct_on! [Db.group …]` (keys reuse the `Group` vocabulary, pair with
  `order_by!` to pick the surviving row). Mutually exclusive (last set wins).
  `render_distinct` emits the modifier between `SELECT ` and the select list (reuses
  `render_more_groups` for the keys); empty `distinct_on!` panics at build time with
  a pointer to `distinct! ()`. DISTINCT applies to `select_frag` (main query, derived
  tables, CTEs); not the `SELECT 1` EXISTS / scalar-subquery forms (use raw if ever
  needed). Demos: `distinct_ages_query` / `newest_user_per_age_query` in
  `src/Read.saga`, wired into `src/Main.saga`. Rendered SQL verified:
  - `SELECT DISTINCT t0.age AS age FROM users AS t0 ORDER BY t0.age ASC`
  - `SELECT DISTINCT ON (t0.age) … FROM users AS t0 ORDER BY t0.age ASC, t0.id DESC`

---

## 4. Nested correlated subquery alias collision — DONE (2026-06-21)

**Resolved.** Two compiler codegen bugs (effectful call as op arg; then effectful
call nested as a sub-expression of an op arg) were found via minimal repros and
fixed compiler-side. With those in, the effect-based fix works: a single monotonic
alias counter is threaded across the whole query tree via the internal
`peek_aliases`/`commit_aliases` ops, so every table gets a unique alias. Verified —
the nested correlated case now renders distinct aliases:

```sql
... WHERE EXISTS (SELECT 1 FROM posts AS s1 WHERE (s1.author_id = t0.id)
      AND EXISTS (SELECT 1 FROM posts AS s2 WHERE (s2.author_id = t0.id) AND s2.id <> s1.id))
```

(`s1` middle, `s2` inner — the inner correctly references `s1.id`, no shadowing.)
Demo: `users_with_two_posts_query` in `src/Read.saga`. All other subquery forms
re-verified green. The investigation trail below is kept as history.

### (history) originally BLOCKED on a compiler bug

- **Problem:** nested correlated subqueries collide on the fixed `s` alias prefix —
  silently produces wrong SQL rather than a type error, violating the
  "no silent footguns" property held everywhere else.
- **Intended fix (effect-based, clean):** thread a single monotonic alias counter
  across the whole query tree. Two internal `QueryBuild` ops (`peek_aliases` /
  `commit_aliases`) let each subquery builder seed numbering from the enclosing
  scope's counter and commit back the aliases it consumed, so every table anywhere
  gets a unique alias (prefix stays `t`/`s` for readability). Implemented and
  typechecks — but **crashes at runtime** due to a compiler bug (below), so it was
  reverted.

### Compiler bug found (2026-06-21) — effectful fn in argument position

Making the subquery builders effectful means `where_! (Query.exists (…))` calls an
effectful function (`exists` now performs `peek_aliases!`) in the **argument
position** of an op. That miscompiles: the effect lowering produces a malformed
value instead of sequencing the inner effect, so the collected `Expr` is garbage and
`Db.join_exprs` hits a `case_clause` at render time. `join_exprs` is pure saga over
plain ADTs (no FFI in the path) — **not a bridge mismatch**.

Minimal repro at `/tmp/efftest` (CPS-style handler + an effectful function returning
an ADT). Characterization (each case isolated):

- `add! (make_frag ())` — effectful fn in **arg position** of an op → **`case_clause`
  crash**.
- `let f = make_frag (); add! f` — same call in **statement position** → works.
- `add! (pure_frag ())` — **non-effectful** fn in arg position → works.

So the trigger is precisely: an effectful function call whose result is consumed by
an enclosing call (argument position). Workaround in user code is to bind to a `let`
first — but that doesn't help here, since the effectful call is at the *user's* DSL
call site (`where_! (exists …)`), which we don't control.

### Compiler fix #1 (landed) + remaining bug (2026-06-21)

First fix handled an effectful call that **is** the whole op argument
(`add! (make_frag ())`) — so post-fix, `where_! (exists …)`, `in_subquery`, derived
tables, and CTEs all work (with correct global `s1` aliases).

**Remaining bug:** a nested effectful call that is a **strict sub-expression** of an
op's argument is still miscompiled — its result comes back malformed. Two library
forms still crash, both confirmed to be this:

- `select! ({ …, total_posts: Query.scalar_subquery (…) })` — effectful call in an
  **anon-record field** of the op arg → crash in `Core.select`/`sql_projection`.
  (Regression: worked at #3; let-binding it to a statement fixes it.)
- `where_! (Db.and_ [Db.eq_col …, Query.exists (…)])` — effectful call in a **list
  element** passed to pure `and_`, whose result is the op arg → crash in
  `join_exprs`.

Boundary (all isolated in `/tmp/efftest/src/Main.saga`):
- `add! (make_frag ())` — effectful call IS the whole op arg → works (fix #1).
- `let c = combine [make_frag ()]; add! c` — statement position → works.
- `add! (combine [make_frag ()])` and `choose! ({ x: make_frag () })` — effectful
  call nested as a sub-expression of the op arg → **crash**.

So the fix must sequence effectful calls at arbitrary depth within an op argument,
not just at the top.

### Next

- Fix the remaining compiler bug (hand off `/tmp/efftest`), then the effect-based #4
  changes (still in the tree) work as-is — re-verify the two queries above.
- Fallback if ever needed: a non-effectful process-dict alias gensym reset per
  `query` — sidesteps the whole class but adds impure global state.

---

## 5. Nested / aggregated relation loading (the big one) — DONE (2026-06-22)

**Decision: separate-query loading (not JSON), declared *in the query*.** One query per
relation level (Ecto/`selectinload` model), stitched in memory — fits Kraken's
explicit/no-magic ethos and avoids the JSON type-fidelity boundary (no `FromJson` on
domain types).

First cut shipped `Query.associate`/`preload conn parents …` (a 6-positional call
outside the query, with two interchangeable `_ -> k` key lambdas — awkward and a silent
footgun). **Reworked** so relations are part of the query DSL:

```saga
authored_posts = Query.has_many posts (fun u -> u.id) (fun p -> p.author_id)
let posts = Query.preload authored_posts u   -- inside the query closure
select! ({ user: u, posts: posts })          -- row: { user: User, posts: List Post }
Query.all conn (users_with_posts_query ())   -- one call, nested result
```

`has_many` takes two *column* accessors (FK named once) and generates the batched child
query. `preload` injects the parent-key column and returns a `Db.Preloaded child` that
slots into `select!`. Execution is a two-pass decode (`decode_at` now threads `RelData`
and returns `(value, keys)`): pass 1 collects parent keys, the executor batch-loads +
groups each relation (`Dict`, O(n+m)), pass 2 resolves each slot — one query per level,
not N+1; nesting composes. New surface in `lib/Kraken/Db.saga` (`Relation`/`Preloaded`/
`RelData`/`RelKey`, `make_projection`, `project_pair`, `col_projection`, `as_sql`) +
`lib/Kraken/Db/Query.saga` (`has_many`/`preload`); demo `authored_posts` /
`users_with_posts_query` / `load_users_with_posts` in `src/Read.saga`, wired into Main.

Verified offline (typecheck + rendered SQL + full stitch with canned rows through a stub
`Repo`). Surfaced + got fixed a compiler bug (effectful closure stored in a record field;
repro `/tmp/efftest2/run.saga`). Full design, the type-system constraints hit, and
follow-ups (`belongs_to`/1:1, `IN`-key dedup) in `nested-relation-loading.md`.

Compiler footgun found along the way: qualifying the builtin `Dict` type as
`Dicts.Dict` (through a module alias) silently misresolves to a phantom type →
`expected Dict Int Int, got Dict Int Int`. Use bare `Dict`. Repro: `/tmp/dicttest2`.

### (original framing)

- **Problem:** "load each user with their posts as a nested list" has no path beyond
  N+1 or manual reshaping. This is the main expressivity frontier for building a
  real app — explicitly *not* an ORM, but the composable non-ORM version is missing.
- **Fix:** a `json_agg` / `array_agg`-into-nested-decode helper — aggregate children
  into JSONB in SQL, decode through the existing `Jsonb a` path. Fits the current
  model cleanly; would be a standout feature.
- **Status:** design first, then implement. (Ask Claude to sketch the design.)

---

## 6. Consider collapsing the `_sql` API doubling — DONE (decision: keep split, dedup impls) (2026-06-23)

- **Problem:** `eq`/`eq_sql`, `add`/`add_sql`, `coalesce`/`coalesce_sql`, etc. roughly
  double the predicate/arithmetic surface; cost compounds as operators are added.
- **Decision:** keep the public split — the literal-RHS forms (`eq u.age 18`) read
  cleanly and are the common case; collapsing to `eq u.age (lit 18)` would tax the
  common path to clean up the rare column-to-column one. A bare-value `ToSql`
  instance is ambiguous/overlapping (overlaps `Col`/`Sql`), which is why the split
  exists and why full collapse isn't free.
- **What was done instead (the maintenance-dedup middle option):** the duplication
  was *implementation-level*, not surface-level — two parallel rendering bodies per
  operator. Added a private `lit_param : a -> Sql a` (the single place that turns a
  literal into a bare `$n` param, no `::type` cast) and rewrote every literal-RHS op
  as a one-liner over its `_sql` cousin: `eq input value = eq_sql input (lit_param
  value)`, likewise `not_eq`/`gt`/`gte`/`lt`/`lte`, `add`/`sub`/`mul`/`div`,
  `coalesce`. Deleted the `arith_lit` helper (now `lit_param` + `arith_sql`). The
  `_sql` variants are now the primitives; 11 operators went from two rendering
  bodies each to one. **No call-site churn, public surface unchanged, rendered SQL
  byte-identical** (`lit_param` emits the same `param (encode_pg …)` the old inline
  bodies did). Distinct from the existing public `Db.lit`, which wraps a literal as
  `Sql a` *with* an explicit `::type` cast for constants in `select!`/`concat`/CASE
  where PG can't infer the param type — unneeded in operators since the other
  operand supplies the type.
- **Where:** `lib/Kraken/Db.saga` (`lit_param` + the 11 delegations; `arith_lit`
  removed). `saga check` green.

---

## Minor / opportunistic (fold into nearby work)

- **`select!` is nearly decorative** — `query` uses the closure's return value; a
  stray second `select!` is silently ignored. Reads fine as DSL punctuation; just be
  aware. (`lib/Kraken/Db/Query.saga:294`, `:309`)
- **`LIMIT`/`OFFSET` inlined as `show n`** rather than bound params. Safe (typed
  `Int`) but inconsistent with the param model — add a one-line comment that it's
  deliberate. (`lib/Kraken/Db/Query.saga:585`)
