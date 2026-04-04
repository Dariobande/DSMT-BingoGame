-module(main_server).
-behaviour(gen_server).

-include("../include/bingo_records.hrl").

-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(CLEANUP_INTERVAL, 3600000).
-define(SESSION_TIMEOUT, 86400).

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
    
    erlang:send_after(?CLEANUP_INTERVAL, self(), clean_old_sessions),

    {ok, #state{cowboy_nodes = Nodes}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Il timer è scattato! È ora di pulire.
handle_info(clean_old_sessions, State) ->
    io:format("[GARBAGE COLLECTOR] Inizio pulizia sessioni vecchie...~n"),

    Now = erlang:system_time(second),
    ExpirationTime = Now - ?SESSION_TIMEOUT,

    %% Funzione che scorre le sessioni una per una
    F = fun() ->
        mnesia:foldl(
            fun(SessionRecord, Counter) ->
                if 
                    SessionRecord#session.last_active < ExpirationTime ->
                        %% È troppo vecchia! Eliminiamola.
                        mnesia:delete({session, SessionRecord#session.token}),
                        Counter + 1; %% Contiamo quante ne eliminiamo
                    true -> 
                        Counter %% La sessione è valida, andiamo avanti
                end
            end, 
            0, %% Il contatore parte da 0
            session %% Il nome della tabella
        )
    end,

    case mnesia:transaction(F) of
        {atomic, DeletedCount} ->
            io:format("[GARBAGE COLLECTOR] Pulizia completata! Rimosse ~p sessioni fantasma.~n", [DeletedCount]);
        {aborted, Reason} ->
            io:format("[GARBAGE COLLECTOR] Errore durante la pulizia: ~p~n", [Reason])
    end,

    %% Ricarichiamo la sveglia per il prossimo giro!
    erlang:send_after(?CLEANUP_INTERVAL, self(), clean_old_sessions),

    {noreply, State};

%% Gestione eventi di Node Up e Node Down
handle_info({nodeup, Node}, State) ->
    io:format("Nodo online: ~p, ripristino giochi...\n", [Node]),

    %% Recupera tutte le partite in stato 'playing'
    F = fun() -> mnesia:match_object(#game{game_id = '_', status = 'playing', creator = '_', players = '_', drawn_numbers = '_', pot = '_', won_combinations = '_'}) end,
    Games = mnesia:transaction(F),
    
    %% TODO si può levare tutta sta roba, tanto ripartono da soli. Non so come funziona però con Nginx se il nodo cade e poi riparte
    lists:foreach(fun(Game) ->
        GameId = Game#game.game_id,
        Creator = Game#game.creator,
        case global:whereis_name(GameId) of
            undefined ->
                %% Processo perso → lo ricreo
                {ok, _Pid} = game_server:start(GameId, Creator);
                %% TODO restore state
                %% gen_server:call(Pid, {restore_state, Game});
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
    %% TODO gestione rimborso cartelle e rimozione cartelle partite in waiting con processo che non esiste +
    %% TODO poi eliminare questi #game dal DB
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