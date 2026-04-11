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
    %% Read cookies from client during handshake
    CookiesList = cowboy_req:parse_cookies(Req),
    Cookies = maps:from_list(CookiesList),
    SessionToken = maps:get(<<"session_token">>, Cookies, undefined),

    %% Upgrade the HTTP request to a WebSocket connection
    {cowboy_websocket, Req, #{session_token => SessionToken}}.

websocket_init(State) ->
    io:format("~n[WS-INFO] New web socket connection~n"),
    %% Get the token from state
    Token = maps:get(session_token, State, undefined),

    %% If there's no token, the state remains empty
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
                    %% If the session game no longer exists in DB, clean the session
                    %% and force lobby access at next authenticate.
                    io:format("[WS-INFO] Connection granted: ~p~n", [Username]),
                    RealGameId = case mnesia:dirty_read({game, GameId}) of
                                    [#game{game_id=GameId}] ->
                                        GameId;
                                    [] ->
                                        update_game_id(Token, undefined),
                                        undefined
                                 end,
                    {ok, #ws_state{
                        username = Username,
                        game_id = RealGameId,
                        game_pid = resolve_game_pid(RealGameId),
                        session_token = Token
                    }};
                {atomic, {error, not_found}} ->
                    io:format("[ERROR] Token not found: connection denied~n"),
                    {stop, #{reason => token_not_found}};
                {aborted, Reason} ->
                    %% In case of transaction error
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
    io:format("~n[WS-INFO] Connection initialization...~n"),
    case GameId of
        undefined -> 
            io:format("[WS-INFO] Lobby access permitted: ~p~n", [Username]),
            send_lobby(State, Username, atom_to_binary(balance_unchanged, utf8));
        _ -> 
            case GamePid of
                undefined ->
                    %% Game doesn't exist → restart
                    io:format("[WS-INFO] Restarting crashed game server...~n"),
                    case game_server:start(GameId, Username) of
                        {ok, NewGamePid} ->
                            case game_server:reconnect(NewGamePid, Username, self()) of
                                {ok, Cards, Drawn, Won, PlayerCount} -> 
                                    io:format("[WS-INFO] Reconnected to game: ~p~n", [Username]),
                                    %% Insert them in the JSON payload for the frontend:
                                    Reply = jsx:encode(#{
                                        <<"event">> => <<"restore_game">>, 
                                        <<"game_id">> => GameId,
                                        <<"cards">> => Cards,
                                        <<"drawn">> => Drawn,
                                        <<"won">> => Won,
                                        <<"player_count">> => PlayerCount
                                    }),
                                    {reply, {text, Reply}, State#ws_state{game_pid=NewGamePid}};
                                {error, Reason} ->
                                    io:format("[WARNING] User [~p] failed to reconnect: ~p~n", [Username, Reason]),
                                    io:format("[WS-INFO] Lobby access permitted: ~p~n", [Username]),
                                    %% Not authorized → send lobby
                                    send_lobby(State, Username, atom_to_binary(balance_unchanged, utf8))
                            end;
                        {error, {already_started, _StartedPid}} ->
                            io:format("[WARNING] Restart of game_server failed for game ~p: game already started~n", [GameId]),
                            {stop, #{reason => game_server_already_started}};
                        {error, Reason} ->
                            io:format("[WARNING] Restart of game_server failed for game ~p: ~p~n", [GameId, Reason]),
                            update_game_id(State#ws_state.session_token, undefined),
                            io:format("[WS-INFO] Lobby access permitted: ~p~n", [Username]),
                            send_lobby(State, Username, atom_to_binary(balance_unchanged, utf8))
                    end;
                Pid ->
                    io:format("[WS-INFO] Reconnecting to game server...~n"),
                    case game_server:reconnect(Pid, Username, self()) of
                        {ok, Cards, Drawn, Won, PlayerCount} ->
                            %% Reconnect the player to the game
                            io:format("[WS-INFO] Reconnected to game: ~p~n", [Username]),
                            Reply = jsx:encode(#{
                                <<"event">> => <<"restore_game">>, 
                                <<"game_id">> => GameId,
                                <<"cards">> => Cards,
                                <<"drawn">> => Drawn,
                                <<"won">> => Won,
                                <<"player_count">> => PlayerCount
                            }),
                            {reply, {text, Reply}, State#ws_state{game_pid=Pid}};
                        {error, Reason} ->
                            io:format("[WARNING] User [~p] failed to reconnect: ~p~n", [Username, Reason]),
                            io:format("[WS-INFO] Lobby access permitted: ~p~n", [Username]),
                            %% Not authorized → send lobby
                            send_lobby(State, Username, atom_to_binary(balance_unchanged, utf8))
                    end
            end
    end;

%% 2. THE SWISS GUARD (Protection of other functions)
%% If a client tries to send "claim_win" or "buy_card" but still has username = undefined...
handle_client_action(_Action, _Data, State = #ws_state{username = undefined}) ->
    %% ...we block it by returning an error!
    io:format("[WARNING] Game operation without being logged~n"),
    Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"reason">> => <<"Please login again">>}),
    {reply, {text, Reply}, State};

handle_client_action(<<"search_open_games">>, _Data, State = #ws_state{username = Username, game_pid = undefined}) ->
    io:format("[WS-INFO] Lobby access permitted: ~p~n", [Username]),
    %% Get current balance from db
    F = fun() ->
        case mnesia:read(user, Username) of
            [User] ->
                User#user.balance;
            [] ->
                balance_unchanged
        end
    end,
    Balance = case mnesia:transaction(F) of
        {atomic, CurrentBalance} -> CurrentBalance;
        {aborted, _Reason} -> balance_unchanged
    end,
    send_lobby(State, Username, Balance);

%% Create a new game
handle_client_action(<<"create_game">>, _Data, State = #ws_state{username = Username, game_pid = undefined, game_id = undefined}) ->
    %% Generate a unique GameId
    RawBytes = crypto:strong_rand_bytes(8),
    GameId = binary:encode_hex(RawBytes),
    
    %% Start the game_server process locally on this node
    {ok, GamePid} = game_server:start(GameId, Username),
    case game_server:join(GamePid, Username, self()) of
        {ok, _PlayerCount} -> 
            io:format("[WS-INFO] New game created by: ~p~n", [Username]),
    
            update_game_id(State#ws_state.session_token, GameId),
            Reply = jsx:encode(#{<<"event">> => <<"game_created">>, <<"game_id">> => GameId}),
            {reply, {text, Reply}, State#ws_state{username = Username, game_pid = GamePid}};
        {error, Reason} ->
            io:format("[WARNING] User [~p] join failed: ~p~n", [Username, Reason]),
            Reply = jsx:encode(#{<<"event">> => <<"error">>,  <<"reason">> => atom_to_binary(Reason, utf8)}),
            {reply, {text, Reply}, State}
    end;
    
    
handle_client_action(<<"create_game">>, _Data, State = #ws_state{username = Username, game_pid = _Pid, game_id = _GameId}) ->
    %% The user is already in a game
    io:format("[WARNING] User tried to create a new game while already being in a game: ~p~n", [Username]),
    Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"reason">> => <<"You are already in game!">>}),
    {reply, {text, Reply}, State};

%% Join an existing game
handle_client_action(<<"join_game">>, Data, State = #ws_state{username = Username, game_pid = undefined, game_id = undefined}) ->
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
            case game_server:join(GamePid, Username, self()) of
                {ok, PlayerCount} -> 
                    io:format("[WS-INFO] User joined a new game: ~p~n", [Username]),
                    update_game_id(State#ws_state.session_token, GameId),
                    Reply = jsx:encode(#{<<"event">> => <<"joined">>, <<"game_id">> => GameId, <<"player_count">> => PlayerCount}),
                    %% Update state of the WS connection with the username and game PID
                    {reply, {text, Reply}, State#ws_state{username = Username, game_pid = GamePid}};
                {error, Reason} ->
                    io:format("[WARNING] User [~p] join failed: ~p~n", [Username, Reason]),
                    Reply = jsx:encode(#{<<"event">> => <<"error">>,  <<"reason">> => atom_to_binary(Reason, utf8)}),
                    {reply, {text, Reply}, State}
            end
    end;

handle_client_action(<<"join_game">>, _Data, State = #ws_state{username = Username, game_pid = _Pid, game_id = _GameId}) ->
    %% The user is already in a game
    io:format("[WARNING] User tried to join a new game while already being in a game: ~p~n", [Username]),
    Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"reason">> => <<"You are already in game!">>}),
    {reply, {text, Reply}, State};

%% Handle undefined game
handle_client_action(_Action, _Data, State = #ws_state{username = Username, game_pid = undefined}) ->
    %% ...we block it by returning an error!
    io:format("[WARNING] User tried to do a game operation on non existing game: ~p~n", [Username]),
    Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"reason">> => <<"You are not in game!">>}),
    {reply, {text, Reply}, State};

%% Leave an existing game
handle_client_action(<<"leave_game">>, _Data, State = #ws_state{username = User, game_pid = GamePid}) ->   
    case game_server:leave(GamePid, User) of
        {ok, Balance} -> 
            io:format("[WS-INFO] User left the game: ~p~n", [User]),
            update_game_id(State#ws_state.session_token, undefined),
            send_lobby(State, User, <<"leave_game">>, Balance);
        {game_cancelled, Balance} ->
            io:format("[WS-INFO] Creator left the game (game cancelled): ~p~n", [User]),
            update_game_id(State#ws_state.session_token, undefined),
            send_lobby(State, User, <<"game_cancelled">>, Balance);
        {error, Reason} ->
            io:format("[WARNING] User denied to buy a card: ~p~n", [User]),
            Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"reason">> => atom_to_binary(Reason, utf8)}),
            {reply, {text, Reply}, State}
    end;

%% Buy a card
handle_client_action(<<"buy_card">>, _Data, State = #ws_state{username = User, game_pid = Pid}) ->
    case game_server:buy_card(Pid, User) of
        {ok, Card, Balance} ->
            io:format("[WS-INFO] User bought a card: ~p~n", [User]),
            Reply = jsx:encode(#{<<"event">> => <<"card_bought">>, <<"grid">> => Card#card.grid, <<"card_id">> => Card#card.card_id, <<"balance">> => Balance}),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            io:format("[WARNING] User denied to buy a card: ~p~n", [User]),
            Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"reason">> => atom_to_binary(Reason, utf8)}),
            {reply, {text, Reply}, State}
    end;

%% Ready to play
handle_client_action(<<"ready_to_play">>, _Data, State = #ws_state{username = User, game_pid = Pid}) ->
    case game_server:ready_to_play(Pid, User) of 
        ok -> 
            io:format("[WS-INFO] User ready to play: ~p~n", [User]),
            {ok, State};
    {error, Reason} -> 
            io:format("[WARNING] User [~p] ready to play failed: ~p~n", [User, Reason]),
            Reply = jsx:encode(#{<<"event">> => <<"error">>,  <<"reason">> => atom_to_binary(Reason, utf8)}),
            {reply, {text, Reply}, State}
    end;

%% Start the game (Creator only)
handle_client_action(<<"start_game">>, _Data, State = #ws_state{username = User, game_pid = Pid}) ->
    case game_server:start_game(Pid, User) of
        ok ->
            io:format("[WS-INFO] User started the game: ~p~n", [User]),
            {ok, State};
        {error, Reason} -> 
            io:format("[WARNING] User [~p] start game failed: ~p~n", [User, Reason]),
            Reply = jsx:encode(#{<<"event">> => <<"error">>,  <<"reason">> => atom_to_binary(Reason, utf8)}),
            {reply, {text, Reply}, State}
    end;

%% Claim a winning combination
handle_client_action(<<"claim_win">>, Data, State = #ws_state{username = User, game_pid = Pid}) ->
    Combination = binary_to_atom(maps:get(<<"combination">>, Data), utf8),
    CardId = maps:get(<<"card_id">>, Data, undefined),
    Numbers = maps:get(<<"numbers">>, Data, []),
    
    case game_server:claim_win(Pid, User, Combination, CardId, Numbers) of
        {ok, Prize, Balance} ->
            io:format("[WS-INFO] User [~p] claimed winning combination: ~p~n", [User, Combination]),
            Reply = jsx:encode(#{<<"event">> => <<"win_accepted">>, <<"prize">> => Prize, <<"balance">> => Balance, <<"combination">> => atom_to_binary(Combination, utf8)}),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            io:format("[WS-INFO] User [~p] failed to claim winning combination [~p]: ~p~n", [User, Combination, Reason]),
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

send_lobby(State, Username, Balance) ->
    send_lobby(State, Username, <<"show_open_games">>, Balance).

send_lobby(State, Username, Event, Balance) ->
    AvailableGames = find_open_games(),
    Reply = jsx:encode(#{<<"event">> => Event, <<"open_games">> => AvailableGames, <<"balance">> => Balance}),
    {reply, {text, Reply}, State#ws_state{username=Username, game_pid=undefined, game_id = undefined}}.

%% Handle incoming Erlang messages from the game_server
%% These are the broadcasts (number drawn, game started, etc.)
websocket_info({game_event, {number_drawn, Num}}, State) ->
    Payload = jsx:encode(#{<<"event">> => <<"number_drawn">>, <<"number">> => Num}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {winner, User, Comb, Prize}}, State) ->
    io:format("[WS-INFO] Claim win event received for user ~p~n", [State#ws_state.username]),
    Payload = jsx:encode(#{<<"event">> => <<"winner_announced">>, <<"user">> => list_to_binary(User), <<"combination">> => atom_to_binary(Comb, utf8), <<"prize">> => Prize}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {game_started, Pot}}, State) ->
    io:format("[WS-INFO] Game started event received for user ~p~n", [State#ws_state.username]),
    Payload = jsx:encode(#{<<"event">> => <<"game_started">>, <<"pot">> => Pot}),
    {reply, {text, Payload}, State};

websocket_info({game_event, game_over}, State) ->
    io:format("[WS-INFO] Game over event received for user ~p~n", [State#ws_state.username]),
    Payload = jsx:encode(#{<<"event">> => <<"game_over">>}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {user_left, User}}, State) ->
    io:format("[WS-INFO] User left event received for user ~p~n", [State#ws_state.username]),
    Payload = jsx:encode(#{<<"event">> => <<"user_left">>, <<"user">> => list_to_binary(User)}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {user_reconnected, User}}, State) ->
    io:format("[WS-INFO] User reconnected event received for user ~p~n", [State#ws_state.username]),
    Payload = jsx:encode(#{<<"event">> => <<"user_reconnected">>, <<"user">> => list_to_binary(User)}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {user_disconnected, User}}, State) ->
    io:format("[WS-INFO] User disconnected event received for user ~p~n", [State#ws_state.username]),
    Payload = jsx:encode(#{<<"event">> => <<"user_disconnected">>, <<"user">> => list_to_binary(User)}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {user_joined, User}}, State) ->
    io:format("[WS-INFO] User joined event received for user ~p~n", [State#ws_state.username]),
    Payload = jsx:encode(#{<<"event">> => <<"user_joined">>, <<"user">> => list_to_binary(User)}),
    {reply, {text, Payload}, State};

websocket_info({game_event, all_ready}, State) ->
    io:format("[WS-INFO] All users ready event received for user ~p~n", [State#ws_state.username]),
    Payload = jsx:encode(#{<<"event">> => <<"all_ready">>}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {user_ready, User}}, State) ->
    io:format("[WS-INFO] User ready event received for user ~p~n", [State#ws_state.username]),
    Payload = jsx:encode(#{<<"event">> => <<"user_ready">>, <<"user">> => list_to_binary(User)}),
    {reply, {text, Payload}, State};

websocket_info({game_event, {game_cancelled, Balance}}, State) ->
    io:format("[WS-INFO] Game cancelled event received for user ~p~n", [State#ws_state.username]),
    update_game_id(State#ws_state.session_token, undefined),
    send_lobby(State, State#ws_state.username, <<"game_cancelled">>, Balance);

websocket_info({game_event, {game_recovered, GamePid}}, State) ->
    io:format("[WS-INFO] Game restored event received for user ~p~n", [State#ws_state.username]),
    NewState = State#ws_state{game_pid = GamePid},
    {ok, NewState};

websocket_info(_Info, State) ->
    {ok, State}.