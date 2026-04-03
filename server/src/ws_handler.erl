-module(ws_handler).
-behaviour(cowboy_websocket).

-include("../include/bingo_records.hrl").

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

%% State of the WS connection
-record(ws_state, {
    username = undefined,
    game_id = undefined,
    game_pid = undefined,
    session_token = undefined
}).

init(Req, _State) ->
    %% Legge i cookie dal client durante handshake
    Cookies = cowboy_req:cookies(Req),
    SessionToken = maps:get(<<"session_token">>, Cookies, undefined),

    %% Upgrade the HTTP request to a WebSocket connection
    {cowboy_websocket, Req, #{session_token => SessionToken}}.

websocket_init(State) ->
    %% Ottieni il token dal state
    Token = maps:get(session_token, State, undefined),

    %% Se non c'è token, lo state resta vuoto
    case Token of
        undefined ->
            io:format("[ERROR] Invalid session token: connection denied~n"),
            {stop, #{reason => no_token}};
        _ ->
            F = fun() ->
                    case mnesia:read({session, Token}) of
                        [#session{username=Username, game_id=GameId}] ->
                            {ok, Username, GameId};
                        [] ->
                            {error, not_found}
                    end
                end,
            case mnesia:transaction(F) of
                {atomic, {ok, Username, GameId}} ->
                    %% Trova PID della partita se esiste
                    io:format("[CONNECTION] New websocket connection: ~p~n", [Username]),
                    {ok, #ws_state{
                        username = Username,
                        game_id = GameId,
                        game_pid = resolve_game_pid(GameId),
                        session_token = Token
                    }};
                {atomic, {error, not_found}} ->
                    io:format("[ERROR] Token not found: connection denied~n"),
                    {stop, #{reason => token_not_found}};
                {aborted, Reason} ->
                    %% In caso di errore di transazione
                    io:format("[ERROR] Db error: ~p~n", [Reason]),
                    {stop, #{reason => db_error}}
            end
    end.

%% Handle incoming JSON messages from the Client via WebSocket
websocket_handle({text, Msg}, State) ->
    Data = jsx:decode(Msg, [return_maps]),
    Action = maps:get(<<"action">>, Data),
    handle_client_action(Action, Data, State);

websocket_handle(_Data, State) ->
    {ok, State}.

%% --- Client Actions ---

handle_client_action(<<"ping">>, _Data, State) ->
    {ok, State};

%% Authenticate the user using the token provided after login
handle_client_action(<<"authenticate">>, _Data, State = #ws_state{username = Username, game_id = GameId, game_pid = GamePid}) ->
    case GameId of
        io:format("[WS-INFO] Lobby access permitted: ~p~n", [Username]),
        undefined -> send_lobby(State, Username);
        _ -> 
            case GamePid of
                undefined ->
                    %% Partita non esiste → ritiriamo su
                    {ok, NewGamePid} = game_server:start(GameId, Username),
                    io:format("[WS-INFO] Crashed game server restarted~n"),
                    %% ritornare le cartelle del cazzo al coglione
                    %% ritornare numeri estratti al coglione
                    %% ritornare anche combinazioni vincenti uscite
                    %% aggiornare WSPID dell'utente riconnesso
                    %% TODO tutto implementato in reconnect
                    {ok, GameState} = game_server:reconnect(NewGamePid, Username, self()),
                    io:format("[WS-INFO] Reconnected to game: ~p~n", [Username]),
                    Reply = jsx:encode(#{<<"event">> => <<"restore_game">>, <<"game_id">> => GameId, <<"game_state">> => GameState}),
                    {reply, {text, Reply}, State#ws_state{game_pid=NewGamePid}};
                Pid ->
                    %% TODO is_player_in_game
                    case game_server:is_player_in_game(Pid, Username) of
                        true ->
                            %% Ricollega il giocatore alla partita
                            {ok, GameState} = game_server:reconnect(Pid, Username, self()),
                            io:format("[WS-INFO] Reconnected to game: ~p~n", [Username]),
                            Reply = jsx:encode(#{<<"event">> => <<"restore_game">>, <<"game_id">> => GameId, <<"game_state">> => GameState}),
                            {reply, {text, Reply}, State#ws_state{game_pid=Pid}};
                        false ->
                            io:format("[WARNING] User tried to connect to another game: ~p~n", [Username]),
                            io:format("[WS-INFO] Lobby access permitted: ~p~n", [Username]),
                            %% Non autorizzato → manda lobby
                            send_lobby(State, Username)
                    end
            end
    end;

%% 2. LA GUARDIA SVIZZERA (Protezione delle altre funzioni)
%% Se un client prova a mandare "claim_win" o "buy_card" ma ha ancora username = undefined...
handle_client_action(_Action, _Data, State = #ws_state{username = undefined}) ->
    %% ...lo blocchiamo restituendo un errore!
    io:format("[WARNING] Game operation without being in game: ~p~n", [Username]),
    Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"message">> => <<"Non sei autenticato!">>}),
    {reply, {text, Reply}, State};

handle_client_action(<<"search_open_games">>, _Data, State = #ws_state{username = Username, game_pid = undefined}) ->
    io:format("[WS-INFO] Lobby access permitted: ~p~n", [Username]),
    AvailableGames = find_open_games(),
    Reply = jsx:encode(#{ <<"event">> => <<"show_open_games">>, <<"open_games">> => AvailableGames }),
    {reply, {text, Reply}, State};

%% Create a new game
handle_client_action(<<"create_game">>, _Data, State = #ws_state{username = Username, game_pid = undefined}) ->
    %% Genera un GameId unico 
    RawBytes = crypto:strong_rand_bytes(8),
    GameId = binary:encode_hex(RawBytes),
    
    %% Start the game_server process locally on this node
    {ok, GamePid} = game_server:start(GameId, Username),
    game_server:join(GamePid, Username, self()),

    io:format("[WS-INFO] New game created by: ~p~n", [Username]),
    
    update_game_id(State#ws_state.session_token, GameId),
    Reply = jsx:encode(#{<<"event">> => <<"game_created">>, <<"game_id">> => GameId}),
    {reply, {text, Reply}, State#ws_state{username = Username, game_pid = GamePid}};
    
handle_client_action(<<"create_game">>, _Data, State = #ws_state{username = Username, game_pid = _Pid}) ->
    %% l'utente è già in gioco
    io:format("[WARNING] User tried to create a new game while already being in a game: ~p~n", [Username]),
    Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"message">> => <<"Sei già in una partita!">>}),
    {reply, {text, Reply}, State};

%% Join an existing game
handle_client_action(<<"join_game">>, Data, State = #ws_state{username = Username}) ->
    GameId = maps:get(<<"game_id">>, Data),

    %% Search for the game process using the global registry
    case global:whereis_name(GameId) of
        undefined ->
            %% The game was not found, send an error back to the client
            io:format("[WARNING] User tried to join non existing game: ~p~n", [Username]),
            Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"reason">> => <<"game_not_found">>}),
            {reply, {text, Reply}, State};
            
        GamePid ->
            %% Found the game, join it
            {ok, PlayerCount} = game_server:join(GamePid, Username, self()),
            io:format("[WS-INFO] User joined a new game: ~p~n", [Username]),
            update_game_id(State#ws_state.session_token, GameId),
            Reply = jsx:encode(#{<<"event">> => <<"joined">>, <<"game_id">> => GameId, <<"player_count">> => PlayerCount}),
            %% Update state of the WS connection with the username and game PID
            {reply, {text, Reply}, State#ws_state{username = Username, game_pid = GamePid}}
    end;

%% Handle undefined game
handle_client_action(_Action, _Data, State = #ws_state{username = Username, game_pid = undefined}) ->
    %% ...lo blocchiamo restituendo un errore!
    io:format("[WARNING] User tried to do an operation on non existing game: ~p~n", [Username]),
    Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"message">> => <<"You are not in game!">>}),
    {reply, {text, Reply}, State};

%% Leave an existing game
handle_client_action(<<"leave_game">>, _Data, State = #ws_state{username = User, game_pid = GamePid}) ->   
    game_server:leave(GamePid, User),
    io:format("[WS-INFO] User left the game: ~p~n", [User]),
    update_game_id(State#ws_state.session_token, undefined),
    AvailableGames = find_open_games(),
    Reply = jsx:encode(#{<<"event">> => <<"leave_game">>, <<"open_games">> => AvailableGames}),
    
    %% Update state of the WS connection: remove game PID
    {reply, {text, Reply}, State#ws_state{username = User, game_pid = undefined}};

%% Buy a card
handle_client_action(<<"buy_card">>, _Data, State = #ws_state{username = User, game_pid = Pid}) ->
    case game_server:buy_card(Pid, User) of
        {ok, Card, Balance} ->
            io:format("[WS-INFO] User bought a card: ~p~n", [User]),
            Reply = jsx:encode(#{<<"event">> => <<"card_bought">>, <<"grid">> => Card#card.grid, <<"balance">> => Balance}),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            io:format("[WARNING] User denied to buy a card: ~p~n", [User]),
            Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"reason">> => atom_to_binary(Reason, utf8)}),
            {reply, {text, Reply}, State}
    end;

%% Start the game (Creator only)
handle_client_action(<<"start_game">>, _Data, State = #ws_state{username = User, game_pid = Pid}) ->
    io:format("[WS-INFO] User started the game: ~p~n", [User]),
    game_server:start_game(Pid, User),
    {ok, State};

%% Claim a winning combination
handle_client_action(<<"claim_win">>, Data, State = #ws_state{username = User, game_pid = Pid}) ->
    Combination = binary_to_atom(maps:get(<<"combination">>, Data), utf8),
    CardId = maps:get(<<"card_id">>, Data),
    
    case game_server:claim_win(Pid, User, Combination, CardId) of
        {ok, Prize, Balance} ->
            Reply = jsx:encode(#{<<"event">> => <<"win_accepted">>, <<"prize">> => Prize, <<"balance">> => Balance}),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"reason">> => atom_to_binary(Reason, utf8)}),
            {reply, {text, Reply}, State}
    end.

%% Trova tutte le partite in attesa e le formatta per il JSON
find_open_games() ->
    %% 1. Creiamo un "identikit" della partita che stiamo cercando.
    %% Il simbolo '_' significa "non mi importa cosa c'è in questo campo".
    Pattern = #game{status = waiting, _ = '_'},
    
    %% 2. Chiediamo a Mnesia di trovare tutti i record che matchano
    OpenGamesRecords = mnesia:dirty_match_object(game, Pattern),

    %% Filtra solo quelli con processo attivo GLOBALMENTE
    ActiveGames = lists:filter(fun(Game) ->
        GameId = Game#game.game_id,
        case global:whereis_name(GameId) of
            undefined -> false;
            _Pid -> true
        end
    end, OpenGamesRecords),
    LimitedGames = lists:sublist(ActiveGames, 10),
    
    %% 3. jsx non sa leggere i record di Erlang, quindi li trasformiamo 
    %% in una comoda lista di mappe!
    lists:map(fun(Game) ->
        #{
            <<"game_id">> => Game#game.game_id,
            <<"status">> => <<"waiting">>,
            <<"creator">> => Game#game.creator,
            <<"player_count">> => length(Game#game.players)
        }
    end, LimitedGames).

update_game_id(Token, NewGameId) ->
    F = fun() ->
        case mnesia:read(session, Token) of
            [] -> 
                {error, not_found};
            [Record] ->
                Now = erlang:system_time(second),
                NewRecord = Record#session{game_id = NewGameId, last_active = Now},
                mnesia:write(NewRecord),
                {ok, NewRecord}
        end
    end,
    mnesia:transaction(F).

resolve_game_pid(undefined) -> undefined;
resolve_game_pid(GameId) ->
    case global:whereis_name(GameId) of
        undefined -> undefined;
        Pid -> Pid
    end.

send_lobby(State, Username) ->
    AvailableGames = find_open_games(),
    Reply = jsx:encode(#{<<"event">> => <<"show_open_games">>, <<"open_games">> => AvailableGames}),
    {reply, {text, Reply}, State#ws_state{username=Username, game_pid=undefined, game_id = undefined}}.

%% Handle incoming Erlang messages from the game_server
%% These are the broadcasts (number drawn, game started, etc.)
websocket_info({game_event, {number_drawn, Num}}, State) ->
    Payload = jsx:encode(#{<<"event">> => <<"number_drawn">>, <<"number">> => Num}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {winner, User, Comb, Prize}}, State) ->
    Payload = jsx:encode(#{<<"event">> => <<"winner_announced">>, <<"user">> => list_to_binary(User), <<"combination">> => atom_to_binary(Comb, utf8), <<"prize">> => Prize}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {game_started, Pot}}, State) ->
    Payload = jsx:encode(#{<<"event">> => <<"game_started">>, <<"pot">> => Pot}),
    {reply, {text, Payload}, State};

websocket_info({game_event, game_over}, State) ->
    Payload = jsx:encode(#{<<"event">> => <<"game_over">>}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {user_left, User}}, State) ->
    Payload = jsx:encode(#{<<"event">> => <<"user_left">>, <<"user">> => list_to_binary(User)}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {user_reconnected, User}}, State) ->
    Payload = jsx:encode(#{<<"event">> => <<"user_reconnected">>, <<"user">> => list_to_binary(User)}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {user_disconnected, User}}, State) ->
    Payload = jsx:encode(#{<<"event">> => <<"user_disconnected">>, <<"user">> => list_to_binary(User)}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {user_joined, User}}, State) ->
    Payload = jsx:encode(#{<<"event">> => <<"user_joined">>, <<"user">> => list_to_binary(User)}),
    {reply, {text, Payload}, State};

websocket_info({game_event, game_cancelled}, State) ->
    AvailableGames = find_open_games(),
    Payload = jsx:encode(#{<<"event">> => <<"game_cancelled">>, <<"open_games">> => AvailableGames}),
    {reply, {text, Payload}, State#ws_state{game_pid = undefined}};

websocket_info(_Info, State) ->
    {ok, State}.