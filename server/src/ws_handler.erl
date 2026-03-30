-module(ws_handler).
-behaviour(cowboy_websocket).

-include("../include/bingo_records.hrl").

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

%% State of the WS connection
-record(ws_state, {
    username = undefined,
    game_pid = undefined
}).

init(Req, State) ->
    %% Upgrade the HTTP request to a WebSocket connection 
    {cowboy_websocket, Req, State}.

websocket_init(_State) ->
    {ok, #ws_state{}}.

%% Handle incoming JSON messages from the Client via WebSocket
websocket_handle({text, Msg}, State) ->
    Data = jsx:decode(Msg, [return_maps]),
    Action = maps:get(<<"action">>, Data),
    handle_client_action(Action, Data, State);

websocket_handle(_Data, State) ->
    {ok, State}.

%% --- Client Actions ---

%% Create a new game
handle_client_action(<<"create_game">>, Data, State) ->
    Username = binary_to_list(maps:get(<<"username">>, Data)),
    GameId = binary_to_list(maps:get(<<"game_id">>, Data)),
    
    %% Start the game_server process locally on this node
    {ok, GamePid} = game_server:start_link(GameId, Username),
    game_server:join(GamePid, Username, self()),
    
    Reply = jsx:encode(#{<<"event">> => <<"game_created">>, <<"game_id">> => list_to_binary(GameId)}),
    {reply, {text, Reply}, State#ws_state{username = Username, game_pid = GamePid}};

%% Join an existing game
handle_client_action(<<"join_game">>, Data, State) ->
    Username = binary_to_list(maps:get(<<"username">>, Data)),
    GameId = binary_to_list(maps:get(<<"game_id">>, Data)),

    %% Search for the game process using the global registry
    case global:whereis_name(GameId) of
        undefined ->
            %% The game was not found, send an error back to the client
            Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"reason">> => <<"game_not_found">>}),
            {reply, {text, Reply}, State};
            
        GamePid ->
            %% Found the game, join it
            game_server:join(GamePid, Username, self()),
            Reply = jsx:encode(#{<<"event">> => <<"joined">>}),
            
            %% Update state of the WS connection with the username and game PID
            {reply, {text, Reply}, State#ws_state{username = Username, game_pid = GamePid}}
    end;

%% Buy a card
handle_client_action(<<"buy_card">>, _Data, State = #ws_state{username = User, game_pid = Pid}) ->
    case game_server:buy_card(Pid, User) of
        {ok, Card, Balance} ->
            Reply = jsx:encode(#{<<"event">> => <<"card_bought">>, <<"grid">> => Card#card.grid, <<"balance">> => Balance}),
            {reply, {text, Reply}, State};
        {error, Reason} ->
            Reply = jsx:encode(#{<<"event">> => <<"error">>, <<"reason">> => atom_to_binary(Reason, utf8)}),
            {reply, {text, Reply}, State}
    end;

%% Start the game (Creator only)
handle_client_action(<<"start_game">>, _Data, State = #ws_state{username = User, game_pid = Pid}) ->
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

websocket_info(_Info, State) ->
    {ok, State}.