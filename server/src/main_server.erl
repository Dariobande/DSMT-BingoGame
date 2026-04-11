-module(main_server).
-behaviour(gen_server).

-include("../include/bingo_records.hrl").

-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(CLEANUP_INTERVAL, 3600000).
-define(SESSION_TIMEOUT, 86400).
-define(CARD_COST, 10).

%% The state maintains the list of nodes to monitor
-record(state, {cowboy_nodes = []}).

%% Starting the Main Server by passing it the list of Cowboy nodes (e.g. ['node1@localhost', 'node2@localhost'])
start_link(Nodes) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Nodes, []).

init(Nodes) ->
    io:format("~nMain Server initialization...~n"),
    %% Explicit connection to nodes
    [net_adm:ping(Node) || Node <- Nodes],
    
    %% Activation of node monitoring
    net_kernel:monitor_nodes(true),
    io:format("Connection established with nodes: ~p~n", [Nodes]),
    
    %% Distributed DB initialization
    %% Also include the current node (node()) to have a DB copy on the Main Server
    AllNodes = [node() | Nodes],
    db_manager:init_cluster_db(AllNodes),
    io:format("Db started~n"),
    erlang:send_after(?CLEANUP_INTERVAL, self(), clean_old_sessions),
    io:format("Session cleaner started~n"),
    io:format("Main server started correctly~n~n"),
    {ok, #state{cowboy_nodes = Nodes}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Timer activated! Time to clean.
handle_info(clean_old_sessions, State) ->
    io:format("~n[GARBAGE COLLECTOR] Session cleaning...~n"),

    Now = erlang:system_time(second),
    ExpirationTime = Now - ?SESSION_TIMEOUT,

    %% Function that goes through sessions one by one
    F = fun() ->
        mnesia:foldl(
            fun(SessionRecord, Counter) ->
                if 
                    SessionRecord#session.last_active < ExpirationTime ->
                        %% It's too old! Delete it.
                        mnesia:delete({session, SessionRecord#session.token}),
                        Counter + 1; %% Count how many we delete
                    true -> 
                        Counter %% The session is valid, let's continue
                end
            end, 
            0, %% The counter starts from 0
            session %% The name of the table
        )
    end,

    case mnesia:transaction(F) of
        {atomic, DeletedCount} ->
            io:format("[GARBAGE COLLECTOR] Cleaning completed! ~p non-active sessions removed.~n", [DeletedCount]);
        {aborted, Reason} ->
            io:format("[GARBAGE COLLECTOR] Error during session cleaning: ~p~n", [Reason])
    end,

    %% Reload the alarm for the next round!
    erlang:send_after(?CLEANUP_INTERVAL, self(), clean_old_sessions),
    {noreply, State};

%% Handling Node Up and Node Down events
handle_info({nodeup, Node}, State) ->
    io:format("[NODEUP] Node ~p is up, db update in progress...~n", [Node]),

    %% Realign the returned node to the Mnesia cluster (including ram_copies).
    ensure_node_db_consistency(Node),
    
    {noreply, State};

handle_info({nodedown, Node}, State) ->
    io:format("~n[MONITOR] WARNING! Node went OFFLINE: ~p~n", [Node]),
    %% In case of down, Mnesia and clients (via Nginx) will handle failover to other nodes.

    F = fun() -> mnesia:match_object(#game{game_id = '_', status = 'waiting', creator = '_', players = '_', drawn_numbers = '_', pot = '_', won_combinations = '_'}) end,
    case mnesia:transaction(F) of
        {atomic, Games} ->
            lists:foreach(fun(Game) ->
                GameId = Game#game.game_id,
                case global:whereis_name(GameId) of
                    undefined ->
                        %% Lost process → atomic cleanup to prevent race condition with game_server recovery
                        cleanup_waiting_game_atomic(GameId);
                    _Pid ->
                        %% Already exists → skip
                        ok
                end
            end, Games);
        {aborted, Reason} ->
            io:format("[ERROR] Error during waiting room game cleaning after node (~p) down: ~p~n", [Node, Reason])
    end,
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, _State = #state{cowboy_nodes = Nodes}) ->
    io:format("Main Server in terminate: ~p. Monitored nodes: ~p~n", [Reason, Nodes]),
    
    %% Example: eventual DB cleanup or timer cancellation
    db_manager:cleanup_cluster_db(Nodes),

    %% Shutting down remote nodes
    [rpc:call(Node, erlang, halt, []) || Node <- Nodes],
    
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% --- Internal functions ---

ensure_node_db_consistency(Node) ->
    Tables = [user, session, game, card],

    %% Avvia Mnesia sul nodo rientrato e collegalo al cluster DB.
    case rpc:call(Node, mnesia, start, []) of
        ok -> ok;
        {error, {already_started, mnesia}} -> ok;
        Other -> io:format("[MONITOR] Start Mnesia on ~p: ~p~n", [Node, Other])
    end,
    mnesia:change_config(extra_db_nodes, [Node]),
    rpc:call(Node, mnesia, change_config, [extra_db_nodes, [node()]]),

    %% Re-attacha le copie tabella con il tipo previsto (disc/ram).
    ensure_table_copy(user, Node, disc_copies),
    ensure_table_copy(game, Node, disc_copies),
    ensure_table_copy(session, Node, ram_copies),
    ensure_table_copy(card, Node, ram_copies),

    %% Aspetta che le tabelle siano disponibili anche sul nodo rientrato.
    case rpc:call(Node, mnesia, wait_for_tables, [Tables, 15000]) of
        ok -> 
            io:format("[MONITOR] Mnesia Db correctly started and updated on node  ~p: ~p~n", [Node, Other]),
            ok;
        {timeout, Missing} ->
            io:format("[MONITOR] Timeout wait_for_tables on node ~p: ~p~n", [Node, Missing]);
        Error ->
            io:format("[MONITOR] wait_for_tables error on node ~p: ~p~n", [Node, Error])
    end.

ensure_table_copy(Table, Node, Type) ->
    case mnesia:add_table_copy(Table, Node, Type) of
        {atomic, ok} ->
            io:format("[MONITOR] Table ~p (~p) correctly updated on node ~p~n", [Table, Type, Node]);
        {aborted, {already_exists, Table, Node}} ->
            ok;
        {aborted, Reason} ->
            io:format("[MONITOR] Table ~p updated failed on node ~p: ~p~n", [Table, Node, Reason])
    end.

%%% ATOMIC cleanup function: cancella cartelle, rimborsa e cancella partita in ONE transaction
%%% Previene race condition quando nodo crasha + client riconnette
cleanup_waiting_game_atomic(GameId) ->
    F = fun() ->
        case mnesia:read(game, GameId) of
            [] -> 
                {ok, []}; % Partita non esiste
            [GameRecord] ->
                Players = GameRecord#game.players,
                
                % Per ogni player: trova carte, cancella, rimborsa e prepara notifica WS post-commit
                Notifications = lists:foldl(
                    fun(PlayerTuple, Acc) ->
                        {Username, PlayerWsPid} = case PlayerTuple of
                            {U, WsPid, _Ready} -> {U, WsPid};
                            {U, WsPid} -> {U, WsPid};
                            U -> {U, undefined}
                        end,

                        Cards = mnesia:match_object(#card{user_id = Username, game_id = GameId, _ = '_'}),
                        Refund = length(Cards) * ?CARD_COST,

                        lists:foreach(
                            fun(Card) ->
                                mnesia:delete_object(Card)
                            end,
                            Cards
                        ),

                        case mnesia:read(user, Username) of
                            [User] ->
                                NewBalance = User#user.balance + Refund,
                                mnesia:write(User#user{balance = NewBalance}),
                                io:format("[CLEANUP] Refunded ~p to ~p~n", [Refund, Username]),
                                case is_pid(PlayerWsPid) of
                                    true -> [{PlayerWsPid, NewBalance} | Acc];
                                    false -> Acc
                                end;
                            [] ->
                                io:format("[CLEANUP] User ~p not found for refund~n", [Username]),
                                Acc
                        end
                    end,
                    [],
                    Players
                ),
                
                % Cancella la partita
                mnesia:delete({game, GameId}),
                io:format("[CLEANUP] Game ~p removed correctly from Db~n", [GameId]),
                {ok, Notifications}
        end
    end,
    io:format("[CLEANUP] Cleaning of game ~p in progress...~n", [GameId]),
    case mnesia:transaction(F) of
        {atomic, {ok, Notifications}} ->
            lists:foreach(
                fun({PlayerWsPid, PlayerBalance}) ->
                    PlayerWsPid ! {game_event, {game_cancelled, PlayerBalance}}
                end,
                Notifications
            ),
            io:format("[CLEANUP] Game ~p cleaning completed~n", [GameId]),
            ok;
        {aborted, Reason} ->
            io:format("[CLEANUP] Error during game ~p cleaning: ~p~n", [GameId, Reason]),
            {error, Reason}
    end.