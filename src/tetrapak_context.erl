% Copyright 2010-2011, Travelping GmbH <info@travelping.com>

% Permission is hereby granted, free of charge, to any person obtaining a
% copy of this software and associated documentation files (the "Software"),
% to deal in the Software without restriction, including without limitation
% the rights to use, copy, modify, merge, publish, distribute, sublicense,
% and/or sell copies of the Software, and to permit persons to whom the
% Software is furnished to do so, subject to the following conditions:

% The above copyright notice and this permission notice shall be included in
% all copies or substantial portions of the Software.

% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
% DEALINGS IN THE SOFTWARE.

%% @private
-module(tetrapak_context).
-export([new/1, run_sequentially/2, shutdown/1,
         wait_for/2, wait_shutdown/1, update_cache/2,
         register_io_worker/1, register_tasks/2, get_tasks/1,
         import_config/2]).
-export([init/2, loop/1]).

-include("tetrapak.hrl").
-define(TIMEOUT, 10000).

update_cache(Ctx, Result) ->
    call(Ctx, {update_cache, Result}).

register_io_worker(Ctx) ->
    link(Ctx),
    cast(Ctx, register_io_worker).

register_tasks(Ctx, TList) ->
    call(Ctx, {register_tasks, TList}).

get_tasks(Ctx) ->
    call(Ctx, get_tasks).

import_config(Ctx, Config = #config{}) ->
    call(Ctx, {import_config, Config}).

-spec run_sequentially(pid(), [Key, ...]) -> ok | {error, Error} | CtxExit when
    Error   :: {failed, Key} | {cycle, [Key, ...]} | {unknown_key, Key},
    Key     :: string(),
    CtxExit :: {context_exit, term()}.
run_sequentially(Context, []) ->
    shutdown(Context);
run_sequentially(Context, [Task | Rest]) ->
    case wait_for(Context, [Task]) of
        ok ->
            run_sequentially(Context, Rest);
        {error, {unknown_key, Key}} ->
            shutdown(Context),
            {error, {unknown_key, Key}};
        {error, {failed, Key}} ->
            wait_shutdown(Context),
            {error, {failed, Key}};
        Exit = {context_exit, _Reason} ->
            Exit
    end.

-spec shutdown(pid()) -> ok.
shutdown(Context) ->
    cast(Context, shutdown),
    wait_shutdown(Context).

-spec wait_for(pid(), [Key, ...]) -> ok | {error, Error} | CtxExit when
    Error   :: {failed, Key} | {cycle, [Key, ...]} | {unknown_key, Key},
    Key     :: string(),
    CtxExit :: {context_exit, term()}.
wait_for(Ctx, Keys) ->
    case call(Ctx, {wait_for, Keys}) of
        {error, Error} ->
            {error, Error};
        {wait, WaitPids} ->
            wait_tasks_down(Ctx, ordsets:from_list(WaitPids))
    end.

wait_tasks_down(Ctx, WaitPids) ->
    CtxMRef = monitor(process, Ctx),
    wait_tasks_down(Ctx, CtxMRef, WaitPids, ok).

wait_tasks_down(_Ctx, CtxMRef, [], Result) ->
    erlang:demonitor(CtxMRef, [flush]),
    Result;
wait_tasks_down(Ctx, CtxMRef, WaitPids, Result) ->
    receive
        {Ctx, done, Pid} when is_pid(Pid) ->
            wait_tasks_down(Ctx, CtxMRef, ordsets:del_element(Pid, WaitPids), Result);
        {Ctx, failed, Pid, TaskName} when is_pid(Pid) ->
            Error = {error, {failed, TaskName}},
            wait_tasks_down(Ctx, CtxMRef, ordsets:del_element(Pid, WaitPids), Error);
        {'DOWN', CtxMRef, process, Ctx, Reason} ->
            ?DEBUG("wait_tasks_down: context died: ~p", [Reason]),
            {context_exit, Reason}
    end.

wait_shutdown(Process) ->
    ?DEBUG("wait_shutdown: ~p", [Process]),
    MRef = monitor(process, Process),
    receive
        {'DOWN', MRef, process, Process, _Info} -> ok
    end.

%% ------------------------------------------------------------
%% -- server loop
-record(st, {
    directory                  :: string(),
    parent                     :: pid(),
    tasks                      :: [{string(), #task{}}],
    cache                      :: ets:tid(),
    rungraph                   :: digraph(),
    io_workers = ordsets:new() :: list(pid())
}).

new(Directory) ->
    proc_lib:spawn(?MODULE, init, [self(), Directory]).

init(Parent, Directory) ->
    process_flag(trap_exit, true),
    InitialState = #st{directory = Directory, parent = Parent,
                       tasks = tetrapak_task_boot:initial_tmap(),
                       cache = ets:new(?MODULE, [protected, ordered_set]),
                       rungraph = digraph:new([acyclic])},
    digraph:add_vertex(InitialState#st.rungraph, pid_to_list(Parent), Parent),
    loop(InitialState).

loop(LoopState = #st{cache = CacheTable, tasks = TaskMap, rungraph = RunGraph}) ->
    receive
        {request, FromPid, {register_tasks, TList}} ->
            reply(FromPid, ok),
            NewTasks = import_tasks(TList, TaskMap),
            loop(LoopState#st{tasks = NewTasks});

        {request, FromPid, {import_config, Config}} ->
            lists:foreach(fun ({Key, Value}) ->
                                  ets:insert(CacheTable, {{config_value, Key}, Value})
                          end, Config#config.values),
            lists:foreach(fun ({{Type, Instance}, ObjValues}) ->
                                  ets:insert(CacheTable, {{config_object, Type, Instance}, ObjValues})
                          end, Config#config.objects),
            reply(FromPid, ok),
            loop(LoopState);

        {request, FromPid, get_tasks} ->
            reply(FromPid, TaskMap),
            loop(LoopState);

        {request, FromPid, {wait_for, Keys}} ->
            case resolve_keys(TaskMap, Keys) of
                {unknown_key, Key} ->
                    reply(FromPid, {error, {unknown_key, Key}});
                TaskDeps ->
                    case start_deps(TaskDeps, task_name(RunGraph, FromPid), LoopState) of
                        {cycle, Cycle} ->
                            reply(FromPid, {error, {cycle, Cycle}});
                        ReplyWait ->
                            reply(FromPid, {wait, ReplyWait})
                    end
            end,
            loop(LoopState);

        {request, FromPid, {update_cache, Variables}} ->
            lists:foreach(fun ({Key, Value}) ->
                                  ets:insert(CacheTable, {{return_value, Key}, Value})
                          end, Variables),
            reply(FromPid, ok),
            loop(LoopState);

        {cast, FromPid, register_io_worker} ->
            loop(LoopState#st{io_workers = ordsets:add_element(FromPid, LoopState#st.io_workers)});

        {cast, _FromPid, shutdown} ->
            do_shutdown(LoopState, undefined, undefined);

        {'EXIT', DeadPid, normal} ->
            ?DEBUG("EXIT normal: ~p", [DeadPid]),
            handle_exit(RunGraph, DeadPid, fun send_done/3),
            loop(LoopState#st{io_workers = ordsets:del_element(DeadPid, LoopState#st.io_workers)});

        {'EXIT', DeadPid, _OtherReason} ->
            ?DEBUG("EXIT ~p: ~p", [_OtherReason, DeadPid]),
            handle_exit(RunGraph, DeadPid, fun send_failed/3),
            do_shutdown(LoopState, DeadPid, task_name(RunGraph, DeadPid));
        Other ->
            ?DEBUG("ctx other ~p", [Other])
    end.

handle_exit(RunGraph, DeadPid, SendDoneMsg) ->
    case digraph:vertex(RunGraph, DeadPid) of
        {_, TaskName} when is_list(TaskName) ->
            digraph:add_vertex(RunGraph, TaskName, done),
            DepTasks = [digraph:edge(RunGraph, E) || E <- digraph:in_edges(RunGraph, TaskName)],
            lists:foreach(fun ({_, Dep, _, _}) ->
                                  {_, DependencyPid} = digraph:vertex(RunGraph, Dep),
                                  is_pid(DependencyPid) andalso SendDoneMsg(DependencyPid, TaskName, DeadPid)
                          end, DepTasks);
        _Else ->
            ok
    end.

send_done(DependencyPid, _DeadName, DeadPid) ->
    DependencyPid ! {self(), done, DeadPid}.
send_failed(DependencyPid, DeadName, DeadPid) ->
    DependencyPid ! {self(), failed, DeadPid, DeadName}.

do_shutdown(#st{rungraph = RunGraph, io_workers = IOWorkers, parent = Parent}, FailedPid, FailedTask) ->
    Vertices = [digraph:vertex(RunGraph, V) || V <- digraph:vertices(RunGraph), is_list(V)],
    Workers = [Pid || {_, Pid} <- Vertices, is_pid(Pid), Pid /= FailedPid, Pid /= Parent],
    ?DEBUG("shutdown: killing task workers: ~p", [Workers]),
    lists:foreach(fun (P) -> erlang:exit(P, kill) end, Workers),
    shutdown_loop(Workers ++ IOWorkers, RunGraph, FailedTask).

shutdown_loop([], _RunGraph, _FailedTask) ->
    ok;
shutdown_loop(Workers, RunGraph, FailedTask) ->
    ?DEBUG("shutdown: ~p", [Workers]),
    receive
        {'EXIT', Pid, normal} ->
            ?DEBUG("shutdown EXIT normal: ~p", [Pid]),
            handle_exit(RunGraph, Pid, fun send_done/3),
            shutdown_loop(lists:delete(Pid, Workers), RunGraph, FailedTask);
        {'EXIT', Pid, _OtherReason} ->
            ?DEBUG("shutdown EXIT ~p: ~p", [_OtherReason, Pid]),
            handle_exit(RunGraph, Pid, fun send_failed/3),
            shutdown_loop(lists:delete(Pid, Workers), RunGraph, FailedTask);
        {cast, FromPid, register_io_worker} ->
            shutdown_loop([FromPid | Workers], RunGraph, FailedTask);
        Other ->
            ?DEBUG("shutdown other ~p", [Other]),
            shutdown_loop(Workers, RunGraph, FailedTask)
    end.

start_deps(Dependencies, Caller, State = #st{rungraph = Graph}) ->
    lists:foreach(fun (Task) ->
                          case digraph:vertex(Graph, Task#task.name) of
                              false ->
                                  digraph:add_vertex(Graph, Task#task.name, not_yet_running);
                              _ ->
                                  ok
                          end
                  end, Dependencies),
    case add_edges(Dependencies, Caller, Graph) of
        {cycle, Cycle} ->
            {cycle, Cycle};
        ok ->
            lists:foldl(fun (Task, WaitAcc) ->
                                maybe_start_task(Task, State, WaitAcc)
                        end, [], Dependencies)
    end.

add_edges([Task | Rest], Caller, Graph) ->
    case digraph:add_edge(Graph, Caller, Task#task.name) of
        {error, {bad_edge, Cycle}} ->
            {cycle, Cycle};
        ['$e' | _] ->
            add_edges(Rest, Caller, Graph)
    end;
add_edges([], _Caller, _Graph) ->
    ok.

maybe_start_task(Task = #task{name = TaskName}, State, WaitAcc) ->
    case digraph:vertex(State#st.rungraph, TaskName) of
        {_, done} ->
            WaitAcc;
        {_, not_yet_running} ->
            Pid = spawn_worker(self(), Task, State),
            digraph:add_vertex(State#st.rungraph, TaskName, Pid),
            digraph:add_vertex(State#st.rungraph, Pid, TaskName),
            [Pid | WaitAcc];
        {_, Pid} when is_pid(Pid) ->
            [Pid | WaitAcc]
    end.

spawn_worker(Ctx, Task, State) ->
    spawn_link(tetrapak_task, worker, [Task, Ctx, State#st.directory, State#st.cache]).

task_name(RunGraph, Pid) ->
    case digraph:vertex(RunGraph, Pid) of
        {_Pid, Name} when is_list(Name) -> Name;
        _            when is_pid(Pid)   -> pid_to_list(Pid)
    end.

resolve_keys(TaskMap, Keys) ->
    try
        lists:foldl(fun (RawKey, Acc) ->
                          Key = tetrapak_task:normalize_name(RawKey),
                          [First | Rest] = tetrapak_task:split_name(Key),
                          Matches = descending_lookup(TaskMap, [First], Rest),
                          %% check for direct matches
                          case lists:filter(fun (#task{name = TN}) -> TN == Key end, Matches) of
                              [DirectMatch] ->
                                  lists:keymerge(#task.name, [DirectMatch], Acc);
                              _ ->
                                  lists:keymerge(#task.name, Matches, Acc)
                          end
                    end, [], Keys)
    catch
        throw:{unknown, Key} ->
            {unknown_key, Key}
    end.

descending_lookup(TaskMap, Prefix, KeyRest) ->
    Matches = [{SKey, Task} || {SKey, Task} <- TaskMap, lists:prefix(Prefix, SKey)],
    case {Matches, KeyRest} of
        {[], _}           -> throw({unknown, string:join(Prefix ++ KeyRest, ":")});
        {_, []}           -> [Task || {_K, Task} <- Matches];
        {[{_K, Task}], _} -> [Task]; %% required key is in output variables
        {_, [Next | KR]}  -> descending_lookup(Matches, Prefix ++ [Next], KR)
    end.

import_tasks(NewTasks, TaskMap) ->
    MergeHooks = fun (_Key, OldTask, NewTask) ->
                         NewTask#task{must_run_before = OldTask#task.must_run_before,
                                      must_run_after = OldTask#task.must_run_after}
                 end,
    MergedTaskMap = orddict:merge(MergeHooks, TaskMap, lists:keysort(1, NewTasks)),
    lists:foldl(fun ({_, Task}, TMAcc1) ->
                    TMAcc2 = apply_hooks(Task, #task.must_run_before, #task.pre_hooks, TMAcc1),
                    apply_hooks(Task, #task.must_run_after, #task.post_hooks, TMAcc2)
                end, MergedTaskMap, NewTasks).

%% preprend Task's name to the ToHookField list of every task given in FromHookField
%% this is so we don't have to write the same code twice for
%% must_run_before and must_run_after
apply_hooks(Task, FromHookField, ToHookField, TaskMap) ->
    lists:foldl(fun (Hooked, TMAcc) ->
                        HookedName = tetrapak_task:split_name(Hooked),
                        case orddict:find(HookedName, TMAcc) of
                            {ok, HookedTask} ->
                                NewHookList = [Task#task.name | element(ToHookField, HookedTask)],
                                NewHookedTask = setelement(ToHookField, HookedTask, NewHookList),
                                orddict:store(HookedName, NewHookedTask, TMAcc);
                            error ->
                                TMAcc
                        end
                end, TaskMap, element(FromHookField, Task)).

%% ------------------------------------------------------------
%% -- micro gen_server
call(Ctx, Request) ->
    call(Ctx, Request, infinity).
call(Ctx, Request, Timeout) ->
    Ctx ! {request, self(), Request},
    receive
        {reply, Ctx, Reply} -> Reply
    after
        Timeout -> exit(context_reply_timeout)
    end.

cast(Ctx, Cast) ->
    Ctx ! {cast, self(), Cast}.

reply(Pid, Reply) ->
    Pid ! {reply, self(), Reply}.
