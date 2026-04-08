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

    %% Riallinea il nodo rientrato al cluster Mnesia (incluse ram_copies).
    ensure_node_db_consistency(Node),

    %% Recupera tutte le partite in stato 'playing'
    F = fun() -> mnesia:match_object(#game{game_id = '_', status = 'playing', creator = '_', players = '_', drawn_numbers = '_', pot = '_', won_combinations = '_'}) end,
    case mnesia:transaction(F) of
        {atomic, Games} ->
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
            end, Games);
        {aborted, Reason} ->
            io:format("[MONITOR] Errore nel recupero giochi su nodeup (~p): ~p~n", [Node, Reason])
    end,
    
    {noreply, State};

handle_info({nodedown, Node}, State) ->
    io:format("~n[MONITOR] ATTENZIONE! Nodo andato OFFLINE: ~p~n", [Node]),
    %% In caso di down, Mnesia e i client (tramite Nginx) gestiranno il failover sugli altri nodi.
    %% Potremmo aggiungere qui logiche di allerta o riavvio container via os:cmd se necessario in futuro.
    %% TODO gestione rimborso cartelle e rimozione cartelle partite in waiting con processo che non esiste +
    %% TODO poi eliminare questi #game dal DB

    F = fun() -> mnesia:match_object(#game{game_id = '_', status = 'waiting', creator = '_', players = '_', drawn_numbers = '_', pot = '_', won_combinations = '_'}) end,
    case mnesia:transaction(F) of
        {atomic, Games} ->
            lists:foreach(fun(Game) ->
                GameId = Game#game.game_id,
                Players = Game#game.players,
                case global:whereis_name(GameId) of
                    undefined ->
                        %% Processo perso → lo gestione rimborsi, cartelle e cancellazione
                        remove_players_cards(Players, GameId),
                        delete_game(GameId);
                    _Pid ->
                        %% Esiste già → skip
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
    
    %% Esempio: eventuale pulizia DB o cancellazione timer
    db_manager:cleanup_cluster_db(Nodes),

    %% Arresto dei nodi remoti
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
        Other -> io:format("[MONITOR] Start Mnesia su ~p: ~p~n", [Node, Other])
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
        ok -> ok;
        {timeout, Missing} ->
            io:format("[MONITOR] Timeout wait_for_tables su ~p: ~p~n", [Node, Missing]);
        Error ->
            io:format("[MONITOR] wait_for_tables errore su ~p: ~p~n", [Node, Error])
    end.

ensure_table_copy(Table, Node, Type) ->
    case mnesia:add_table_copy(Table, Node, Type) of
        {atomic, ok} ->
            io:format("[MONITOR] Aggiunta copia ~p (~p) su ~p~n", [Table, Type, Node]);
        {aborted, {already_exists, Table, Node}} ->
            ok;
        {aborted, Reason} ->
            io:format("[MONITOR] add_table_copy fallita ~p su ~p: ~p~n", [Table, Node, Reason])
    end.

remove_players_cards(Users, GameId) ->
    %% TODO for each User in Users, in GameId, remove cards and add cards prize to balance
    Pattern = #card{user_id = Username, game_id = GameId, _ = '_'},
    Cards = mnesia:dirty_match_object(card, Pattern),
    Refund = length(Cards) * ?CARD_COST,
    lists:foreach(
        fun(Card) ->
            mnesia:dirty_delete_object(Card)
        end,
        Cards
    ),
    F = fun() ->
        [User] = mnesia:read(user, Username),
        NewBalance = User#user.balance + Refund,
        mnesia:write(User#user{balance = NewBalance}),
        NewBalance
    end,
    case mnesia:transaction(F) of
        {atomic, UpdatedBalance} ->
            UpdatedBalance;
        {aborted, Reason} ->
            io:format("[REFUND] Failed to update balance for ~p: ~p~n", [Username, Reason]),
            {error, refund_failed}
    end.

delete_game(GameId) ->
    %% Operazione Mnesia distribuita
    F = fun() ->
        mnesia:delete({game, GameId})
    end,
    case mnesia:transaction(F) of
        {atomic, ok} ->
            io:format("Partita ~p cancellata con successo da Mnesia~n", [GameId]),
            ok;
        {aborted, Reason} ->
            io:format("Errore cancellando partita ~p: ~p~n", [GameId, Reason]),
            {error, Reason}
    end.