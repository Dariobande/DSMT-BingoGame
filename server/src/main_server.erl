-module(main_server).
-behaviour(gen_server).

-include("../include/bingo_records.hrl").

-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Lo stato mantiene la lista dei nodi da monitorare
-record(state, {cowboy_nodes = []}).

%% Avvio del Main Server passandogli la lista dei nodi Cowboy (es. ['node1@localhost', 'node2@localhost'])
start_link(Nodes) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Nodes, []).

init(Nodes) ->
    io:format("Main Server in avvio... Connessione ai nodi: ~p~n", [Nodes]),
    
    %% Connessione esplicita ai nodi
    [net_adm:ping(Node) || Node <- Nodes],
    
    %% Attivazione del monitoraggio dei nodi
    net_kernel:monitor_nodes(true),
    
    %% Inizializzazione del DB distribuito
    %% Includiamo anche il nodo corrente (node()) per avere una copia del DB sul Main Server
    AllNodes = [node() | Nodes],
    db_manager:init_cluster_db(AllNodes),
    
    {ok, #state{cowboy_nodes = Nodes}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Gestione eventi di Node Up e Node Down
handle_info({nodeup, Node}, State) ->
    io:format("Nodo online: ~p, ripristino giochi...\n", [Node]),

    %% Recupera tutte le partite in stato 'playing' o 'waiting'
    F = fun() -> mnesia:match_object(#game{game_id = '_', status = '_', creator = '_', players = '_', drawn_numbers = '_', pot = '_'}) end,
    Games = mnesia:transaction(F),
    
    lists:foreach(fun(Game) ->
        GameId = Game#game.game_id,
        Creator = Game#game.creator,
        case global:whereis_name(GameId) of
            undefined ->
                %% Processo perso → lo ricreo
                {ok, Pid} = game_server:start_link(GameId, Creator),
                gen_server:call(Pid, {restore_state, Game});
            _Pid ->
                %% Esiste già → skip
                ok
        end
    end, Games),

    {noreply, State};

handle_info({nodedown, Node}, State) ->
    io:format("~n[MONITOR] ATTENZIONE! Nodo andato OFFLINE: ~p~n", [Node]),
    %% In caso di down, Mnesia e i client (tramite Nginx) gestiranno il failover sugli altri nodi.
    %% Potremmo aggiungere qui logiche di allerta o riavvio container via os:cmd se necessario in futuro.
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, _State = #state{cowboy_nodes = Nodes}) ->
    io:format("Main Server in terminate: ~p. Monitored nodes: ~p~n", [Reason, Nodes]),
    
    %% Esempio: eventuale pulizia DB o cancellazione timer
    db_manager:cleanup_cluster_db(Nodes),

    %% Arresto dei nodi remoti
    [rpc:call(Node, erlang, halt, []) || Node <- Nodes],
    
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.