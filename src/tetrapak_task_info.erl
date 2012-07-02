-module(tetrapak_task_info).
-export([run/2]).
-compile([export_all]).

-type application() :: atom().
-type dep_tree() :: {application(), Dependencies :: [dep_tree()]}.

run("info:deps", _) ->
    show_flat(get_dependencies_in_start_order(tetrapak:get("config:appfile:name")));
run("info:deps:tree", _) ->
    show_tree([get_dependencies(tetrapak:get("config:appfile:name"))], []).

show_flat(Applications) ->
    Names = lists:map(fun atom_to_list/1, Applications),
    io:put_chars(string:join(Names, ", ")),
    io:nl().

show_tree([], _Depth) ->
    ok;
show_tree([{App, Dependencies} | Rest], Depth) ->
    case Depth of
        [] -> ok;
        _  ->
            lists:foreach(fun (true)  -> io:put_chars("|   ");
                              (false) -> io:put_chars("    ")
                          end, tl(lists:reverse(Depth))),
            case Rest of
                [] -> io:put_chars("`-- ");
                _  -> io:put_chars("|-- ")
            end
    end,
    case Dependencies of
        {not_found, _} ->
            io:format("~s [NOT INSTALLED]~n", [App]);
        _Deps ->
            io:format("~s~n", [App]),
            show_tree(Dependencies, [(Rest /= []) | Depth])
    end,
    show_tree(Rest, Depth).

-spec get_dependencies(application()) -> dep_tree().
get_dependencies(App) ->
    case application:load(App) of
        ok -> get_deps(App);
        {error, {already_loaded, App}} -> get_deps(App);
        {error, Reason} -> {App, {not_found, Reason}}
    end.

get_deps(App) ->
    {ok, Deps} = application:get_key(App, applications),
    GoodDeps = [get_dependencies(D) || D <- lists:sort(Deps),
                   not lists:member(D, [kernel, stdlib])],
    {App, GoodDeps}.

-spec get_dependencies_in_start_order(application()) -> [application()].
get_dependencies_in_start_order(App) ->
    start_order([get_dependencies(App)], []).

-spec start_order([dep_tree()], [application()]) -> [application()].
start_order([{App, {not_found, Error}} | _Rest], _Started) ->
    tetrapak:fail("Dependency ~s not installed. Rerun with -tree to see what depends on it.~n   ~p",
                  [App, Error]);
start_order([{App, Deps} | Rest], Started) ->
    case lists:member(App, Started) of
        true  -> start_order(Rest, Started);
        false -> start_order(Rest, [App | start_order(Deps, Started)])
    end;
start_order([], Started) ->
    lists:reverse(Started).
