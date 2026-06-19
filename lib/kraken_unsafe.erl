-module(kraken_unsafe).
-export([from_dynamic/1, slice_all_null/3]).

from_dynamic(Value) ->
    Value.

%% True when every column in [Offset, Offset + Width) of a result row is SQL
%% NULL. Rows come back as tuples or lists (0-indexed); pgo represents NULL as
%% the atom `null` (we also treat `nil`/`undefined` as null defensively).
slice_all_null(Offset, Width, Row) ->
    all_null(Offset, Offset + Width, Row).

all_null(I, End, _Row) when I >= End ->
    true;
all_null(I, End, Row) ->
    case is_null(elem(I, Row)) of
        true -> all_null(I + 1, End, Row);
        false -> false
    end.

elem(I, Row) when is_tuple(Row) -> element(I + 1, Row);
elem(I, Row) when is_list(Row) -> lists:nth(I + 1, Row).

is_null(null) -> true;
is_null(nil) -> true;
is_null(undefined) -> true;
is_null(_) -> false.
