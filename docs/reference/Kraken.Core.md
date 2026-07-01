---
title: Kraken.Core
---

## Types

### Array

```saga
opaque type Array a
```

### Jsonb

```saga
opaque type Jsonb a
```

### TypeTag

```saga
type TypeTag a =
  | TypeTag
```

A phantom carrier for a type, so a cast can name its target type without having
a value of it.

### Nullable

```saga
opaque type Nullable cols
```

A column scope on the nullable side of a left join.

Wraps a table's column record. Because the joined row may be absent, selecting
a `Nullable` scope yields `Maybe row` rather than `row`.

### Table

```saga
opaque type Table cols
```

### ColRef

```saga
opaque type ColRef
```

An erased column reference (name + source) that drops the value type, so a
primary key can name columns of differing types.

### PrimaryKey

```saga
type PrimaryKey =
  | NoKey
  | Key ColRef
  | Composite (List ColRef)
```

A table's primary key, as declared by `ColumnSet.primary_key`.

### Col

```saga
opaque type Col a
```

### Generated

```saga
opaque type Generated a
```

A column the database fills in (SERIAL / identity / `DEFAULT`). Marking a
schema column `Generated a` instead of `Col a` keeps it readable and usable in
predicates exactly like a normal column, but the type prevents it from being
supplied in an `insert` input — id-omission becomes a type guarantee, not a
convention.

### DefaultValue

```saga
type DefaultValue a =
  | UseDefault
  | Provide a
```

The insert value for a column that may use its table default. `UseDefault`
renders SQL `DEFAULT`; `Provide v` binds an explicit value. This is different
from `Maybe`: `Nothing` binds SQL NULL, while `UseDefault` asks the database to
compute the column default.

### GeneratedValue

```saga
type alias GeneratedValue a = DefaultValue a
```

### SetExpr

```saga
opaque type SetExpr
```

One `column = <expr>` assignment in an upsert `DO UPDATE SET`. Build with `assign`.

### ConflictTarget

```saga
type ConflictTarget =
  | OnColumns (List ColRef)
  | OnConstraint String
```

Where an `ON CONFLICT` detects a collision: a column list
(`on_columns [Db.ref u.id]` → `ON CONFLICT (id)`) or a named constraint
(`on_constraint "users_email_key"` → `ON CONFLICT ON CONSTRAINT users_email_key`).

### SqlPart

```saga
type SqlPart =
  | Text String
  | Param Value
```

### SqlFrag

```saga
record SqlFrag {
  parts: List SqlPart
}
```

### Fragment

```saga
opaque type Fragment
```

### Sql

```saga
opaque type Sql a
```

### SqlArg

```saga
opaque type SqlArg
```

### Expr

```saga
opaque type Expr
```

### SelectItem

```saga
record SelectItem {
  expr: SqlFrag,
  alias: String,
  relabelable: Bool
}
```

### Order

```saga
opaque type Order
```

### Group

```saga
opaque type Group
```

### Field

```saga
opaque type Field a
```

### RelSlot

```saga
type RelSlot =
  | RelSlot Int Int
```

Locates a relation's parent-key column during the first decode pass: the relation's
index (its slot, matching `RelData`) and the column offset of its key in the row.
Both plain ints — the key value itself is read later, typed, from the raw rows.

### RelData

```saga
opaque type RelData
```

Loaded children for each relation, keyed by relation index. The values are the one
irreducible erasure: each is a `Dict parent_key (List child)` held opaquely because
relations in one query have differing `child` types. Empty during the first pass.

### Projection

```saga
opaque type Projection a
```

### Preloaded

```saga
opaque type Preloaded out
```

A relation field in a `select`: it occupies one selected column (its parent
key) but decodes to `out` — the children loaded by a separate query, shaped by
how the relation is consumed (`List child` for a to-many `preload`, `Maybe child`
for a to-one `preload_one`). Built by the query layer; selecting it contributes
the parent-key column to the SELECT and a deferred decode that resolves children
from the executor-supplied `RelData`.

### Selection

```saga
type Selection =
  | Selection
```

### Window

```saga
opaque type Window
```

A window specification — the `OVER (…)` frame. Build with `window`, then add
`partition_by` / `order_window`. Reuses `Db.group` for PARTITION BY and
`Db.asc`/`Db.desc` for the window's ORDER BY.

## Traits

### PgType

```saga
trait PgType a {
  fun encode_pg : a -> Value
  fun decode_pg : Decoder a
}
```

### PgTypeName

```saga
trait PgTypeName a {
  fun pg_type_name : TypeTag a -> String
}
```

The Postgres type name a Saga type casts to (`x::<name>`). Only types you cast
*to* need an instance.

### ColumnSet

```saga
trait ColumnSet cols {
  fun columns : String -> cols
  fun primary_key : cols -> PrimaryKey
}
```

### AsColRef

```saga
trait AsColRef c {
  fun as_col_ref : c -> ColRef
}
```

Columns (`Col` / `Generated`) that can be erased to a `ColRef`.

### ToSql

```saga
trait ToSql input a {
  fun to_sql : input -> Sql a
}
```

### ToArraySql

```saga
trait ToArraySql input a {
  fun to_array_sql : input -> Sql (Array a)
}
```

### ToJsonbSql

```saga
trait ToJsonbSql input a {
  fun to_jsonb_sql : input -> Sql (Jsonb a)
}
```

## Functions

### array

```saga
fun array : List a -> Array a
```

### array_to_list

```saga
fun array_to_list : Array a -> List a
```

### jsonb

```saga
fun jsonb : a -> Jsonb a
```

### jsonb_to_value

```saga
fun jsonb_to_value : Jsonb a -> a
```

### encode_via

```saga
fun encode_via : a -> b -> a -> Value where {b: PgType}
```

Encode `a` by mapping it to a representation `b` that already has `PgType`.
The forward direction is total: `encode_via to_rep`.

### decode_via

```saga
fun decode_via : b -> Result a String -> Decoder a where {b: PgType}
```

Decode `a` from a representation `b` that has `PgType`, via a *fallible*
back-mapping — a stored value may not correspond to any `a` (an unknown enum
label, an unparseable number), so `from_rep` returns `Result a String` and the
`Err` message surfaces as a decode failure.

### enum_text_encode

```saga
fun enum_text_encode : List (a, String) -> a -> Value where {a: Eq}
```

Encode an enum-like type as text via an explicit value→label table, e.g. for a
Postgres `enum` column (or a text column with fixed values). The table is the
single source of truth for the wire labels — which can differ freely from the
Saga constructor names (`SCREAMING_SNAKE` ↔ friendly). Pair with
`enum_text_decode` over the same table in a tiny `impl PgType`:

type Status = Active | Archived deriving (Eq)
status_labels = [(Active, "ACTIVE"), (Archived, "ARCHIVED")]
impl PgType for Status {
encode_pg = enum_text_encode status_labels
decode_pg = enum_text_decode status_labels
}

Panics if `value` is missing from the table (an incomplete mapping is a
programmer error, not a data error).

### enum_text_decode

```saga
fun enum_text_decode : List (a, String) -> Decoder a
```

Decode an enum-like type from text via an explicit value→label table (the
inverse of `enum_text_encode`). An unrecognized label fails the decode rather
than guessing.

### as_nullable

```saga
fun as_nullable : cols -> Nullable cols
```

Mark a column scope as nullable. Used by `left_join!` to wrap the joined
table's columns so that selecting the scope produces `Maybe row`.

### unwrap_cols

```saga
fun unwrap_cols : Nullable cols -> cols
```

Unwrap a nullable scope to its underlying columns.

Use this only to reference a left-joined table's columns in post-join
predicates and ordering (`where_!`, `order_by!`, `having!`) — most commonly an
anti-join such as `is_null (unwrap_cols p).id`. SQL ignores result nullability
in those positions, so the plain columns are appropriate.

Do not use the result in `select`: it selects the columns as non-null and
turns a compile-time `Maybe` into a runtime decode error on absent rows. Join
`ON` clauses never need this — `inner_join!`/`left_join!` already pass their
callback the plain columns.

### key

```saga
fun key : c -> PrimaryKey where {c: AsColRef}
```

Name a single-column primary key (the common case): `primary_key u = key u.id`.

### ref

```saga
fun ref : c -> ColRef where {c: AsColRef}
```

Erase a column to a `ColRef`, for assembling a composite key.

### composite

```saga
fun composite : List ColRef -> PrimaryKey
```

Name a composite (multi-column) primary key.

### primary_key_columns

```saga
fun primary_key_columns : PrimaryKey -> List String
```

The primary key's column names in order (empty for `NoKey`).

### ref_name

```saga
fun ref_name : ColRef -> String
```

The column name a `ColRef` points to (e.g. for an `ON CONFLICT` target).

### default

```saga
fun default : DefaultValue a
```

Use the table's default for this column.

### auto

```saga
fun auto : DefaultValue a
```

Let the database assign a generated column (the common case).

### provide

```saga
fun provide : a -> DefaultValue a
```

Force a specific value into a defaulted or normally-generated column.

### table

```saga
fun table : String -> Table cols where {cols: ColumnSet}
```

### cte_table

```saga
fun cte_table : String -> String -> cols -> Table cols
```

Build a `Table` whose columns come from a supplied scope-builder rather than a
`ColumnSet` — for CTEs and other derived sources, where the columns are whatever
the subquery selected (named by `make_scope` at the reference alias). The result
is referencable by `from!` / `inner_join!` / `left_join!` like any table.

### table_as

```saga
fun table_as : String -> Table cols -> Table cols
```

### table_name

```saga
fun table_name : Table cols -> String
```

### table_alias

```saga
fun table_alias : Table cols -> Maybe String
```

### table_cols

```saga
fun table_cols : String -> Table cols -> cols
```

### col

```saga
fun col : String -> String -> Col a
```

### generated

```saga
fun generated : String -> String -> Generated a
```

Declare a DB-generated column in a `ColumnSet` impl, mirroring `col`.

### encode_value

```saga
fun encode_value : a -> Value where {a: PgType}
```

Encode a value into a Postgres bind parameter via its `PgType` instance.

### col_name

```saga
fun col_name : Col a -> String
```

The bare column name (no table qualifier), e.g. for an `UPDATE ... SET` target.

### generated_name

```saga
fun generated_name : Generated a -> String
```

### excluded

```saga
fun excluded : Col a -> Col a
```

Reference a column on the `EXCLUDED` pseudo-table — the row proposed by the
conflicting insert — inside an upsert `DO UPDATE`: `Db.excluded u.name` renders
`EXCLUDED.name`. The existing row is referenced by the plain column (`u.name`).

### assign

```saga
fun assign : Col a -> rhs -> SetExpr where {rhs: ToSql a}
```

Assign a column an arbitrary SQL expression in a `DO UPDATE SET`. The RHS is any
`ToSql` value of the column's type, so it can combine the existing row, the
proposed row, and literals: `Db.assign u.count (Db.add_sql u.count (Db.excluded
u.count))` → `count = users.count + EXCLUDED.count`. Listing only the columns you
want also gives a partial DO UPDATE (a subset, not the blanket overwrite).

### set_expr_column

```saga
fun set_expr_column : SetExpr -> String
```

### set_expr_frag

```saga
fun set_expr_frag : SetExpr -> SqlFrag
```

### on_columns

```saga
fun on_columns : List ColRef -> ConflictTarget
```

### on_constraint

```saga
fun on_constraint : String -> ConflictTarget
```

### expr_from_frag

```saga
fun expr_from_frag : SqlFrag -> Expr
```

Build a boolean `Expr` from a raw fragment. Used by the query layer to wrap a
rendered subquery (e.g. `EXISTS (…)`) as a predicate; the fragment's `Param`s are
numbered by the enclosing query at render time.

### empty_rel_data

```saga
fun empty_rel_data : RelData
```

The empty relation data used during the first decode pass (and by callers with no
relations at all).

### rel_data_of

```saga
fun rel_data_of : List (Int, Dynamic) -> RelData
```

Build relation data from `(relation index, grouped-children-as-Dynamic)` pairs.

### rel_data_get

```saga
fun rel_data_get : Int -> RelData -> Maybe Dynamic
```

Look up a relation's grouped children (still opaque) by its index.

### make_preloaded

```saga
fun make_preloaded : SelectItem -> RelData -> Int -> Dynamic -> Result (out, List RelSlot) DecodeError -> Preloaded out
```

Build a `Preloaded` field from its injected parent-key column and a resolver. The
query layer supplies both; the resolver closes over the child types and the
to-many/to-one shaping, so `Preloaded` is parameterized only by the output `out`.

### map

```saga
fun map : a -> b -> Projection a -> Projection b
```

### selection

```saga
fun selection : Selection
```

### projection_into

```saga
fun projection_into : a -> b -> Projection (a -> b)
```

Start building a projection for a constructor. This is the explicit primitive
used by `build Selection Record { ... }`.

### projection_with

```saga
fun projection_with : Projection a -> Projection (a -> b) -> Projection b
```

Feed one projected value into a projected constructor. The constructor projection
is the piped value:

build Selection User {
id: Db.read u.id,
name: Db.read u.name,
}

### projection_field

```saga
fun projection_field : String -> Projection a -> Projection (a -> b) -> Projection b
```

### sql_text

```saga
fun sql_text : String -> Fragment
```

### sql_param

```saga
fun sql_param : Value -> Fragment
```

### sql_value

```saga
fun sql_value : a -> Fragment where {a: PgType}
```

### sql_column

```saga
fun sql_column : Col a -> Fragment
```

### sql_from_frag

```saga
fun sql_from_frag : SqlFrag -> Sql a where {a: PgType}
```

Wrap a raw fragment as a typed `Sql a`, decoding the result with `a`'s default
`PgType` decoder. Exposed so the query layer can present a rendered scalar
subquery `(SELECT … )` as a first-class `Sql a`.

### sql

```saga
fun sql : input -> SqlArg where {input: ToSql a}
```

### value

```saga
fun value : a -> SqlArg where {a: PgType}
```

### lit

```saga
fun lit : a -> Sql a where {a: PgType + PgTypeName}
```

A typed literal as a first-class `Sql a`: a bound parameter with an explicit
`::type` cast (`$1::text`). Use it for literals in positions where Postgres can't
infer the parameter type from context — `concat`, `case_when` branches, a bare
`select` of a constant — which otherwise fail with "could not determine data type
of parameter". In a comparison the other operand supplies the type, so `Db.value`
/ the `eq` family don't need this.

### raw

```saga
fun raw : String -> List SqlArg -> Sql a where {a: PgType}
```

### raw_array

```saga
fun raw_array : String -> List SqlArg -> Sql (Array a) where {a: PgType}
```

### raw_array_like

```saga
fun raw_array_like : Col (Array a) -> String -> List SqlArg -> Sql (Array a) where {a: PgType}
```

### expr_raw

```saga
fun expr_raw : String -> List SqlArg -> Expr
```

### expr

```saga
fun expr : Sql Bool -> Expr
```

### expr_frag

```saga
fun expr_frag : Expr -> SqlFrag
```

### frag_of

```saga
fun frag_of : input -> SqlFrag where {input: ToSql a}
```

The SQL fragment of any `ToSql` value (a column, raw expression, aggregate, …).
Exposed so the query layer can build predicates like `IN (subquery)` from a
left-hand value and a rendered subquery.

### cast

```saga
fun cast : input -> Sql b where {input: ToSql a, b: PgType + PgTypeName}
```

A SQL cast: render `(<input>)::<target>` and decode as the target type. The
result is a first-class `Sql b` usable in `select` / predicates. This is a
*typed assertion*, not a checked conversion — you vouch that the cast yields a
`b` (Postgres validates at runtime, like `raw`); Kraken just renders `::b` and
decodes accordingly. The target `b` must be annotated or fixed by an `as_*`
helper, since it isn't determined by the input.

### as_int

```saga
fun as_int : input -> Sql Int where {input: ToSql a}
```

`<input>::integer`.

### as_float

```saga
fun as_float : input -> Sql Float where {input: ToSql a}
```

`<input>::double precision`.

### as_text

```saga
fun as_text : input -> Sql String where {input: ToSql a}
```

`<input>::text` — e.g. a timestamp or number rendered as a string.

### as_bool

```saga
fun as_bool : input -> Sql Bool where {input: ToSql a}
```

`<input>::boolean`.

### as_timestamp

```saga
fun as_timestamp : input -> Sql NaiveDateTime where {input: ToSql a}
```

`<input>::timestamp` — e.g. parse a string column as a timestamp.

### as_date

```saga
fun as_date : input -> Sql Date where {input: ToSql a}
```

`<input>::date`.

### as_time

```saga
fun as_time : input -> Sql Time where {input: ToSql a}
```

`<input>::time`.

### sql_fn

```saga
fun sql_fn : String -> List SqlArg -> Sql a where {a: PgType}
```

A generic SQL function call: `name(arg1, arg2, …)`. Arguments are `SqlArg`s, so
pass columns/expressions with `Db.sql` and literals with `Db.value`. The result
type isn't inferable from the arguments, so annotate it or let the selection fix
it: `Db.sql_fn "lower" [Db.sql u.name] : Db.Sql String`.

### coalesce

```saga
fun coalesce : input -> a -> Sql a where {input: ToSql a, a: PgType}
```

`COALESCE(<input>, <fallback>)` — the first non-NULL of the two. The principled
way to recover a non-null scalar from a left join: after `Db.unwrap_cols`, a
left-joined column reads as `Col a`, and `coalesce` pairs it with a default of
the same type, yielding a non-null `Sql a` you *can* put in `select`
(`Db.coalesce (Db.unwrap_cols p).count 0` → `COALESCE(t1.count, $1)`).

### coalesce_sql

```saga
fun coalesce_sql : left -> right -> Sql a where {left: ToSql a, right: ToSql a, a: PgType}
```

`COALESCE(<left>, <right>)` over two SQL values of the same type (e.g. two
columns) rather than a literal fallback.

### not_

```saga
fun not_ : Expr -> Expr
```

Boolean negation: `NOT (<expr>)`. Complements `and_` / `or_` / `is_null`.

### lower

```saga
fun lower : input -> Sql String where {input: ToSql String}
```

`LOWER(<input>)`.

### upper

```saga
fun upper : input -> Sql String where {input: ToSql String}
```

`UPPER(<input>)`.

### trim

```saga
fun trim : input -> Sql String where {input: ToSql String}
```

`TRIM(<input>)`.

### concat

```saga
fun concat : List SqlArg -> Sql String
```

`CONCAT(arg1, arg2, …)` — NULL arguments are treated as empty (unlike `||`).
Arguments are `SqlArg`s (`Db.sql` for columns, `Db.value` for literals).

### add

```saga
fun add : input -> a -> Sql a where {input: ToSql a, a: PgType}
```

`(<input> + <literal>)` — e.g. the upsert idiom `count = users.count + 1`.

### sub

```saga
fun sub : input -> a -> Sql a where {input: ToSql a, a: PgType}
```

`(<input> - <literal>)`.

### mul

```saga
fun mul : input -> a -> Sql a where {input: ToSql a, a: PgType}
```

`(<input> * <literal>)`.

### div

```saga
fun div : input -> a -> Sql a where {input: ToSql a, a: PgType}
```

`(<input> / <literal>)`.

### add_sql

```saga
fun add_sql : left -> right -> Sql a where {left: ToSql a, right: ToSql a, a: PgType}
```

`(<left> + <right>)` between two SQL values (e.g. `price + tax`).

### sub_sql

```saga
fun sub_sql : left -> right -> Sql a where {left: ToSql a, right: ToSql a, a: PgType}
```

`(<left> - <right>)`.

### mul_sql

```saga
fun mul_sql : left -> right -> Sql a where {left: ToSql a, right: ToSql a, a: PgType}
```

`(<left> * <right>)` — e.g. `price * quantity`.

### div_sql

```saga
fun div_sql : left -> right -> Sql a where {left: ToSql a, right: ToSql a, a: PgType}
```

`(<left> / <right>)`.

### case_when

```saga
fun case_when : List (Expr, SqlArg) -> SqlArg -> Sql a where {a: PgType}
```

`CASE WHEN <cond> THEN <val> … ELSE <else> END`. Each branch pairs a predicate
with a `SqlArg` result; the `else` is the fallback `SqlArg`. Branch and else
values use `Db.sql` (columns/expressions) or `Db.value` (literals). The result
type is fixed by annotation or the selection. Panics with no branches.

### eq

```saga
fun eq : input -> a -> Expr where {input: ToSql a, a: PgType}
```

### not_eq

```saga
fun not_eq : input -> a -> Expr where {input: ToSql a, a: PgType}
```

### gt

```saga
fun gt : input -> a -> Expr where {input: ToSql a, a: PgType}
```

### gte

```saga
fun gte : input -> a -> Expr where {input: ToSql a, a: PgType}
```

### lt

```saga
fun lt : input -> a -> Expr where {input: ToSql a, a: PgType}
```

### lte

```saga
fun lte : input -> a -> Expr where {input: ToSql a, a: PgType}
```

### eq_sql

```saga
fun eq_sql : left -> right -> Expr where {left: ToSql a, right: ToSql a, a: PgType}
```

### eq_col

```saga
fun eq_col : left -> right -> Expr where {left: ToSql a, right: ToSql a, a: PgType}
```

### not_eq_sql

```saga
fun not_eq_sql : left -> right -> Expr where {left: ToSql a, right: ToSql a, a: PgType}
```

Comparisons between two SQL values (columns, expressions, scalar subqueries)
rather than against a literal. The `eq` family compares against a literal RHS;
these compare two `ToSql` operands of the same element type — e.g.
`Db.gt_sql u.age (Db.scalar_subquery …)`.

### gt_sql

```saga
fun gt_sql : left -> right -> Expr where {left: ToSql a, right: ToSql a, a: PgType}
```

### gte_sql

```saga
fun gte_sql : left -> right -> Expr where {left: ToSql a, right: ToSql a, a: PgType}
```

### lt_sql

```saga
fun lt_sql : left -> right -> Expr where {left: ToSql a, right: ToSql a, a: PgType}
```

### lte_sql

```saga
fun lte_sql : left -> right -> Expr where {left: ToSql a, right: ToSql a, a: PgType}
```

### like

```saga
fun like : input -> String -> Expr where {input: ToSql String}
```

### ilike

```saga
fun ilike : input -> String -> Expr where {input: ToSql String}
```

### between

```saga
fun between : input -> a -> a -> Expr where {input: ToSql a, a: PgType}
```

### contains

```saga
fun contains : input -> Array a -> Expr where {input: ToArraySql a, a: PgType}
```

### contained_by

```saga
fun contained_by : input -> Array a -> Expr where {input: ToArraySql a, a: PgType}
```

### overlaps

```saga
fun overlaps : input -> Array a -> Expr where {input: ToArraySql a, a: PgType}
```

### json_contains

```saga
fun json_contains : input -> Jsonb a -> Expr where {input: ToJsonbSql a, a: ToJson + FromJson}
```

### json_has_key

```saga
fun json_has_key : input -> String -> Expr where {input: ToJsonbSql a}
```

### json_text

```saga
fun json_text : input -> String -> Sql String where {input: ToJsonbSql a}
```

### in_

```saga
fun in_ : input -> List a -> Expr where {input: ToSql a, a: PgType}
```

### not_in

```saga
fun not_in : input -> List a -> Expr where {input: ToSql a, a: PgType}
```

### eq_any

```saga
fun eq_any : input -> List a -> Expr where {input: ToSql a, a: PgType}
```

### not_eq_all

```saga
fun not_eq_all : input -> List a -> Expr where {input: ToSql a, a: PgType}
```

### like_any

```saga
fun like_any : input -> List String -> Expr where {input: ToSql String}
```

### ilike_any

```saga
fun ilike_any : input -> List String -> Expr where {input: ToSql String}
```

### is_null

```saga
fun is_null : input -> Expr where {input: ToSql a, a: PgType}
```

### is_not_null

```saga
fun is_not_null : input -> Expr where {input: ToSql a, a: PgType}
```

### and_

```saga
fun and_ : List Expr -> Expr
```

### or_

```saga
fun or_ : List Expr -> Expr
```

### nullable_row

```saga
fun nullable_row : Projection a -> Projection (Maybe a)
```

Adapt a whole-row projection into its nullable form for left joins.

If every column the projection spans is SQL NULL in a result row, it decodes
to `Nothing`; otherwise the row is decoded and wrapped in `Just`. The all-NULL
rule remains correct even when a domain field is itself nullable, since a
matched row still carries at least one non-null required column.

### projection_relabel

```saga
fun projection_relabel : String -> Projection a -> Projection a
```

Relabel a projection for a record field. This is the explicit primitive used by
`build Selection Record { field: projection }`: single-column fields take the field
label directly, while multi-column fields get prefixed labels like `user_id`.

### projection_selections

```saga
fun projection_selections : Projection a -> List SelectItem
```

### make_projection

```saga
fun make_projection : List SelectItem -> Int -> RelData -> Int -> Dynamic -> Result (a, List RelSlot) DecodeError -> Projection a
```

Build a `Projection` from explicit selections, width, and a relation-aware
decoder. Exposed so the query layer can construct a `Preloaded` field's
projection (its single parent-key column plus a deferred child-resolving decode).

### as_sql

```saga
fun as_sql : input -> Sql a where {input: ToSql a}
```

Coerce any column-like value (`Col` / `Generated` / `Sql`) to a `Sql a`. Exposed
so the query layer can accept a relation key as a column accessor regardless of
whether the schema field is a plain or generated column.

### read

```saga
fun read : input -> Projection a where {input: ToSql a}
```

Project any SQL-like value (`Col`, `Generated`, or `Sql`) as a single decoded
column. This is the explicit leaf used by `projection_into` / `projection_with`.

### read_sql

```saga
fun read_sql : Sql a -> Projection a
```

Project an already-built SQL expression. Alias is supplied by the surrounding
projection construction or by the generated select item.

### read_nullable

```saga
fun read_nullable : Nullable cols -> cols -> Projection a -> Projection (Maybe a)
```

Project a nullable scope through a whole-row projection. This keeps the left
join all-NULL sentinel in one named operation instead of making callers unwrap
a scope directly at a `select` site.

### read_preloaded

```saga
fun read_preloaded : Preloaded out -> Projection out
```

Project a preloaded relation field. It contributes the hidden parent-key column
and decodes through the relation data stitched in by the query executor.

### col_select_item

```saga
fun col_select_item : String -> Sql a -> SelectItem
```

A `SelectItem` selecting a single `Sql` value under the given alias. Exposed so
the query layer can inject a relation's parent-key column into the SELECT.

### col_decoder

```saga
fun col_decoder : Sql a -> Int -> Dynamic -> Result a DecodeError
```

A positional decoder for a single `Sql` value, using its own decoder. Exposed so
the query layer can read a relation's parent-key value at decode time.

### col_projection

```saga
fun col_projection : Sql a -> Projection a
```

A single-column `Projection` for a `Sql` value. Exposed so the query layer can
pair a relation's foreign-key column alongside the child row.

### project_pair

```saga
fun project_pair : Projection a -> Projection b -> Projection (a, b)
```

Pair two projections into one yielding a tuple (selections concatenated, widths
summed, decodes threaded). Exposed for relation loading's `(fk, child)` rows.

### decode_projection

```saga
fun decode_projection : Projection a -> RelData -> Dynamic -> Result (a, List RelSlot) DecodeError
```

Decode a result row through a projection, threading relation data and collecting
any relation keys the row's `Preloaded` slots emit. Callers with no relations
pass `empty_rel_data` and ignore the (empty) key list.

### asc

```saga
fun asc : input -> Order where {input: ToSql a, a: PgType}
```

### desc

```saga
fun desc : input -> Order where {input: ToSql a, a: PgType}
```

### group

```saga
fun group : input -> Group where {input: ToSql a, a: PgType}
```

### order_expr

```saga
fun order_expr : Order -> SqlFrag
```

### order_direction

```saga
fun order_direction : Order -> String
```

### group_frag

```saga
fun group_frag : Group -> SqlFrag
```

### count_star

```saga
fun count_star : Sql Int
```

### count

```saga
fun count : input -> Sql Int where {input: ToSql a, a: PgType}
```

### count_distinct

```saga
fun count_distinct : input -> Sql Int where {input: ToSql a, a: PgType}
```

### sum

```saga
fun sum : input -> Sql (Maybe a) where {input: ToSql a, a: PgType}
```

### avg

```saga
fun avg : input -> Sql (Maybe Float) where {input: ToSql a, a: PgType}
```

### min

```saga
fun min : input -> Sql (Maybe a) where {input: ToSql a, a: PgType}
```

### max

```saga
fun max : input -> Sql (Maybe a) where {input: ToSql a, a: PgType}
```

### window

```saga
fun window : Window
```

An empty window (`OVER ()`). Refine it with `partition_by` / `order_window`.

### partition_by

```saga
fun partition_by : List Group -> Window -> Window
```

Set the window's `PARTITION BY` keys.

### order_window

```saga
fun order_window : List Order -> Window -> Window
```

Set the window's `ORDER BY` terms (needed for ranking / running aggregates).

### over

```saga
fun over : Sql a -> Window -> Sql a
```

Turn any `Sql a` into its windowed form: `<expr> OVER (<window>)`. Most useful on
an aggregate for a running / partitioned total —
`Db.over (Db.sum u.amount) (Db.partition_by [Db.group u.dept] Db.window)` →
`SUM(u.amount) OVER (PARTITION BY u.dept)`. The decoder is preserved, so a
windowed `sum` is still `Sql (Maybe a)`.

### row_number

```saga
fun row_number : Window -> Sql Int
```

`ROW_NUMBER() OVER (<window>)` — sequential row number within each partition.

### rank

```saga
fun rank : Window -> Sql Int
```

`RANK() OVER (<window>)` — rank with gaps after ties.

### dense_rank

```saga
fun dense_rank : Window -> Sql Int
```

`DENSE_RANK() OVER (<window>)` — rank without gaps after ties.

### lag

```saga
fun lag : input -> Window -> Sql (Maybe a) where {input: ToSql a, a: PgType}
```

`LAG(<input>) OVER (<window>)` — the value from the previous row in the window
(NULL on the first row, hence `Maybe a`).

### lead

```saga
fun lead : input -> Window -> Sql (Maybe a) where {input: ToSql a, a: PgType}
```

`LEAD(<input>) OVER (<window>)` — the value from the next row in the window
(NULL on the last row, hence `Maybe a`).

