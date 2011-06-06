%    __                        __      _
%   / /__________ __   _____  / /___  (_)___  ____ _
%  / __/ ___/ __ `/ | / / _ \/ / __ \/ / __ \/ __ `/
% / /_/ /  / /_/ /| |/ /  __/ / /_/ / / / / / /_/ /
% \__/_/   \__,_/ |___/\___/_/ .___/_/_/ /_/\__, /
%                           /_/            /____/
%
% Copyright (c) Travelping GmbH <info@travelping.com>

-module(tetrapak_task).
-include("tetrapak.hrl").
-compile({no_auto_import, [get/1]}).

%% task behaviour functions
-export([behaviour_info/1]).
-export([worker/3, context/0, directory/0, fail/0, fail/2, get/2, require_all/1]).
-export([output_collector/3]).
%% misc
-export([normalize_name/1, split_name/1, find_tasks/0]).

-define(CTX, '$__tetrapak_task_context').
-define(DIRECTORY, '$__tetrapak_task_directory').

behaviour_info(callbacks) -> [{run, 2}];
behaviour_info(_) -> undefined.

context() ->
    case erlang:get(?CTX) of
        Ctx when is_pid(Ctx) -> Ctx;
        _AnythingElse        -> error(not_inside_task)
    end.

directory() ->
    case erlang:get(?DIRECTORY) of
        Ctx when is_list(Ctx) -> Ctx;
        _AnythingElse         -> error(not_inside_task)
    end.

worker(#task{name = TaskName, modules = [TaskModule | _OtherModules]}, Context, Directory) ->
    tpk_log:debug("worker: task ~s starting", [TaskName]),

    OutputCollector = spawn_link(?MODULE, output_collector, [Context, TaskName, self()]),
    group_leader(OutputCollector, self()),

    erlang:put(?CTX, Context),
    erlang:put(?DIRECTORY, Directory),
    case try_check(TaskModule, TaskName) of
        {done, Variables} ->
            tetrapak_context:task_done(Context, TaskName, Variables),
            exit({?TASK_DONE, TaskName});
        {needs_run, TaskData} ->
            case try_run(TaskModule, TaskName, TaskData) of
                {done, Variables} ->
                    tetrapak_context:task_done(Context, TaskName, Variables),
                    exit({?TASK_DONE, TaskName})
            end
    end.

try_check(TaskModule, TaskName) ->
    Function = tpk_util:f("~s:check/1", [TaskModule]),
    try
        case TaskModule:check(TaskName) of
            needs_run ->
                {needs_run, undefined};
            {needs_run, Data} ->
                {needs_run, Data};
            done ->
                {done, dict:new()};
            {done, Variables} ->
                {done, do_output_variables(Function, TaskName, Variables)};
            true ->
                {needs_run, undefined};
            false ->
                {done, dict:new()};
            ok ->
                {done, dict:new()};
            OtherInvalid ->
                fail("~s returned an invalid value: ~p", [Function, OtherInvalid])
        end
    catch
        error:Exn ->
            case {Exn, erlang:get_stacktrace()} of
                {undef, [{TaskModule, check, [TaskName]} | _]} ->
                    %% check/1 is undefined, treat it as 'needs_run'
                    {needs_run, undefined};
                {function_clause, [{TaskModule, check, [TaskName]} | _]} ->
                    %% check/1 is defined, but not for this task, treat it as 'needs_run'
                    {needs_run, undefined};
                _ ->
                    handle_error(TaskName, Function, error, Exn)
            end;
        Class:Exn ->
            handle_error(TaskName, Function, Class, Exn)
    end.

try_run(TaskModule, TaskName, TaskData) ->
    Function = tpk_util:f("~s:run/1", [TaskModule]),
    try
        case TaskModule:run(TaskName, TaskData) of
            done ->
                {done, dict:new()};
            {done, Variables} ->
                {done, do_output_variables(Function, TaskName, Variables)};
            ok ->
                {done, dict:new()};
            OtherInvalid ->
                fail("~s returned an invalid value: ~p", [Function, OtherInvalid])
        end
    catch
        Class:Exn ->
            handle_error(TaskName, Function, Class, Exn)
    end.

handle_error(TaskName, _Function, throw, {?TASK_FAIL, Message}) ->
    case Message of
        undefined -> ok;
        _ ->
            io:put_chars(["Error: ", Message, $\n])
    end,
    exit({?TASK_FAIL, TaskName});
handle_error(TaskName, Function, Class, Exn) ->
    io:format("crashed in ~s:~n~p:~p~n~p~n", [Function, Class, Exn, erlang:get_stacktrace()]),
    exit({?TASK_FAIL, TaskName}).

do_output_variables(Fun, TaskName, Vars) when is_list(Vars) ->
    lists:foldl(fun ({Key, Value}, Acc) ->
                        dict:store(TaskName ++ ":" ++ str(Key), Value, Acc);
                    (Item, _Acc) ->
                        fail("~s returned an invalid proplist (item ~p)", [Fun, Item])
                end, dict:new(), Vars);
do_output_variables(_Fun, _TaskName, {Size, nil}) when is_integer(Size) ->
    dict:new();
do_output_variables(_Fun, TaskName, Tree = {Size, {_, _, _, _}}) when is_integer(Size) ->
    tpk_util:fold_tree(fun ({Key, Value}, Acc) ->
                               dict:store(TaskName ++ ":" ++ str(Key), Value, Acc)
                       end, dict:new(), Tree);
do_output_variables(Fun, _TaskName, _Variables) ->
    fail("~s returned an invalid key-value structure (not a proplist() | gb_tree())", [Fun]).

fail() ->
    throw({?TASK_FAIL, undefined}).
fail(Fmt, Args) ->
    throw({?TASK_FAIL, tpk_util:f(Fmt, Args)}).

get(Key, FailUnknown) ->
    case require_all([Key], FailUnknown) of
        ok ->
            tetrapak_context:get_cached(context(), Key);
        {error, {unknown_key, _}} ->
            {error, unknown_key}
    end.

require_all(Keys) ->
    require_all(Keys, false).
require_all(Keys, FailUnknown) when is_list(Keys) ->
    KList = lists:map(fun str/1, Keys),
    case tetrapak_context:wait_for(context(), KList) of
        ok ->
            ok;
        {error, Error} ->
            case {FailUnknown, Error} of
                {_, {failed, Other}}        ->
                    fail("required task '~s' failed", [Other]);
                {false, _} ->
                    {error, Error};
                {true, {unknown_key, Unknown}} ->
                    fail("require/1 of unknown key: ~p", [Unknown])
            end
    end.

%% ------------------------------------------------------------
%% -- Output handler
-define(LineWidth, 30).

output_collector(Context, TaskName, TaskProcess) ->
    receive
        Req = {io_request, _, _, _} ->
            process_flag(trap_exit, true),
            tetrapak_context:task_wants_output(Context, TaskProcess),
            Buffer = handle_io(Req, <<>>),
            output_collector_loop(Context, TaskName, TaskProcess, Buffer)
    end.

output_collector_loop(Context, TaskName, TaskProcess, Buffer) ->
    receive
        Req = {io_request, _, _, _} ->
            NewBuffer = handle_io(Req, Buffer),
            output_collector_loop(Context, TaskName, TaskProcess, NewBuffer);
        {reply, Context, output_ok} ->
            print_output_header(TaskName),
            do_output(console, Buffer),
            output_collector_loop(Context, TaskName, TaskProcess, console);
        {'EXIT', TaskProcess, _Reason} ->
            case Buffer of
                console ->
                    tetrapak_context:task_output_done(Context, TaskProcess);
                _ ->
                    wait_output_ok(Context, TaskName, TaskProcess, Buffer)
            end
    end.

wait_output_ok(Context, TaskName, TaskProcess, Buffer) ->
    receive
        {reply, Context, output_ok} ->
            print_output_header(TaskName),
            do_output(console, Buffer),
            tetrapak_context:task_output_done(Context, TaskProcess)
    end.

handle_io({io_request, From, ReplyAs, Request}, Buffer) ->
    case ioreq_chars([Request], []) of
        {notsup, Chars} ->
            NewBuffer = do_output(Buffer, Chars),
            From ! {io_reply, ReplyAs, {error, request}};
        {ok, Chars} ->
            NewBuffer = do_output(Buffer, Chars),
            From ! {io_reply, ReplyAs, ok}
    end,
    NewBuffer.

do_output(console, Chars) ->
    io:put_chars(Chars),
    console;
do_output(Buffer, Chars) ->
    <<Buffer/binary, (iolist_to_binary(Chars))/binary>>.

ioreq_chars([{put_chars, _Enc, Chars} | R], Acc)   -> ioreq_chars(R, [Chars | Acc]);
ioreq_chars([{put_chars, _Enc, M, F, A} | R], Acc) -> ioreq_chars(R, [apply(M, F, A) | Acc]);
ioreq_chars([{put_chars, Chars} | R], Acc)         -> ioreq_chars(R, [Chars | Acc]);
ioreq_chars([{put_chars, M, F, A} | R], Acc)       -> ioreq_chars(R, [apply(M, F, A) | Acc]);
ioreq_chars([{requests, Requests} | _R], Acc)       -> ioreq_chars(Requests, Acc);
ioreq_chars([_OtherRequest | _R], Acc) ->
    {notsup, lists:reverse(Acc)};
ioreq_chars([], Acc) ->
    {ok, lists:reverse(Acc)}.

print_output_header(TaskName) ->
    io:put_chars(["== ", TaskName, " ", lists:duplicate(max(0, ?LineWidth - length(TaskName)), $=), $\n]).

%% ------------------------------------------------------------
%% -- Beam Scan
find_tasks() ->
    find_tasks([code:lib_dir(tetrapak, ebin)]).
find_tasks(Directories) ->
    lists:foldl(fun (Dir, OuterModAcc) ->
                   tpk_log:debug("checking for task modules in ~s", [Dir]),
                   tpk_file:walk(fun (File, ModAcc) ->
                                    case is_task_module(File) of
                                        false              -> ModAcc;
                                        {Module, TaskDefs} -> store_defs(Module, TaskDefs, ModAcc)
                                    end
                                  end, OuterModAcc, Dir)
                end, [], Directories).

is_task_module(Mfile) ->
    case filename:extension(Mfile) of
        ".beam" ->
            {ok, {ModuleName, Chunks}} = beam_lib:chunks(Mfile, [attributes]),
            Attributes = proplists:get_value(attributes, Chunks, []),
            IsTask = lists:member(?MODULE, proplists:get_value(behaviour, Attributes, [])) orelse
                     lists:member(?MODULE, proplists:get_value(behavior, Attributes, [])),
            if
                IsTask ->
                    case proplists:get_value(task, Attributes) of
                        undefined -> false;
                        InfoList  -> {ModuleName, lists:flatten(InfoList)}
                    end;
                true ->
                    false
            end;
        _ ->
            false
    end.

store_defs(Module, List, TaskMap) ->
    lists:foldl(fun ({TaskName, Desc}, Acc) ->
                        NewTask   = #task{name = normalize_name(TaskName),
                                          modules = [Module],
                                          description = Desc},
                        AddModule = fun (#task{modules = OldMods}) -> NewTask#task{modules = [Module | OldMods]} end,
                        pl_update(split_name(TaskName), AddModule, NewTask, Acc)
               end, TaskMap, List).

pl_update(Key, AddItem, NewItem, Proplist) ->
    case proplists:get_value(Key, Proplist) of
        undefined -> [{Key, NewItem} | Proplist];
        Value     -> [AddItem(Value) | proplists:delete(Key, Proplist)]
    end.

normalize_name(Key) ->
    string:to_lower(string:strip(str(Key))).
split_name(Key) ->
    SplitName = re:split(normalize_name(Key), ":", [{return, list}]),
    lists:filter(fun ([]) -> false;
                     (_)  -> true
                 end, SplitName).

str(Atom) when is_atom(Atom) -> atom_to_list(Atom);
str(Bin) when is_binary(Bin) -> binary_to_list(Bin);
str(Lis)                     -> Lis.