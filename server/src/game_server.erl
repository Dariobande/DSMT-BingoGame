-module(game_server).
-behaviour(gen_server).

-include("../include/bingo_records.hrl").

%% API
-export([start/2, join/3, buy_card/2, start_game/2, claim_win/4, leave/2, is_player_in_game/2, reconnect/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(CARD_COST, 10).
-define(MAX_CARDS, 3).
-define(DRAW_INTERVAL, 5000). %% 5 seconds between each number draw

%% State of the gen_server handling a single game
-record(state, {
    game_id,
    creator,
    status = waiting, %% waiting | playing | finished
    players = [],     %% List of {Username, WsPid}
    drawn = [],       %% List of extracted numbers (1-90)
    pot = 0,          %% Total money collected
    timer_ref = undefined,
    won_combinations = [] %% e.g., [ambo, terno] to prevent double claiming
}).

%% --- API ---

%% Starts a new game process
start(GameId, Creator) ->
    gen_server:start({global, GameId}, ?MODULE, [GameId, Creator], []).

%% User joins the game. WsPid is the Cowboy WebSocket process PID for broadcasting.
join(GamePid, Username, WsPid) ->
    gen_server:call(GamePid, {join, Username, WsPid}).

%% User leaves the game. WsPid is the Cowboy WebSocket process PID for broadcasting.
leave(GamePid, Username) ->
    gen_server:call(GamePid, {leave, Username}).

%% User buys a card
buy_card(GamePid, Username) ->
    gen_server:call(GamePid, {buy_card, Username}).

%% The creator starts the game
start_game(GamePid, Username) ->
    gen_server:call(GamePid, {start_game, Username}).

%% A player claims a winning combination (ambo, terno, etc.)
claim_win(GamePid, Username, Combination, CardId) ->
    gen_server:call(GamePid, {claim_win, Username, Combination, CardId}).

%% Check if a player is in game
is_player_in_game(GamePid, Username) ->
    gen_server:call(GamePid, {is_player_in_game, Username}).

%% Reconnect to started game
reconnect(GamePid, Username, NewWsPid) ->
    gen_server:call(GamePid, {reconnect, Username, NewWsPid}).


%% --- Callbacks ---

init([GameId, Creator]) ->
    %% 1. Controlliamo se la partita esiste già nel Database
    case mnesia:dirty_read(game, GameId) of
        [] ->
            %% CASO A: Nuova Partita! (Comportamento classico)
            io:format("[CREATE] Nuova partita creata da: ~p~n", [Creator]),
            InitialState = #state{
                game_id = GameId, creator = Creator, status = waiting,
                drawn = [], pot = 0, players = [], won_combinations = []
            },
            update_db(InitialState),
            {ok, InitialState};

        [ExistingRecord] ->
            %% CASO B: Recupero post-crash! (Resurrezione)
            io:format("[RECOVERY] Recupero stato partita: ~p~n", [GameId]),

            %% Traduciamo il record di Mnesia nello State del gen_server
            RecoveredState = #state{
                game_id = ExistingRecord#game.game_id,
                creator = ExistingRecord#game.creator,
                status = ExistingRecord#game.status,
                players = ExistingRecord#game.players,
                drawn = ExistingRecord#game.drawn_numbers,
                pot = ExistingRecord#game.pot,
                won_combinations = ExistingRecord#game.won_combinations
            },

            %% Se la partita era 'playing' quando è crashata, facciamo ripartire il timer!
            FinalState = case RecoveredState#state.status of
                playing ->
                    Ref = erlang:send_after(?DRAW_INTERVAL, self(), draw_number),
                    RecoveredState#state{timerref = Ref};
                 ->
                    RecoveredState
            end,

            {ok, FinalState}
    end.

handle_call({join, Username, WsPid}, _From, State = #state{status = waiting, players = Players}) ->
    io:format("[JOIN] New player joined the game: ~p~n",[Username]),
    erlang:monitor(process, WsPid),
    broadcast(Players, {user_joined, Username}),
    %% Update state with new player and their WebSocket PID
    NewPlayers = [{Username, WsPid} | proplists:delete(Username, Players)],
    PlayerCount = length(NewPlayers),

    NewState = State#state{players = NewPlayers},
    update_db(NewState),

    {reply, {ok, PlayerCount}, NewState};

handle_call({leave, Username}, _From, State = #state{creator = Creator, status = Status, players = Players, game_id = GameId}) ->
    case {Username =:= Creator, Status =:= waiting} of
        {true, true} ->
            io:format("[LEAVE] Creator left unstarted game, game cancelled~n"),
            %% Il creatore lascia e la partita è in waiting → cancelliamo la partita
            delete_game(GameId),
            NewPlayers = lists:filter(fun({U, _}) -> U =/= Username end, Players),
            broadcast(NewPlayers, game_cancelled),
            {stop, normal, {game_cancelled, GameId}, State};
        _ ->
            %% Rimuovi il giocatore dalla lista (sia creatore dopo l'inizio del gioco sia giocatore normale)
            io:format("[LEAVE] Player left the game: ~p~n",[Username]),
            NewPlayers = lists:filter(fun({U, _}) -> U =/= Username end, Players),
            broadcast(NewPlayers, {user_left, Username}),

            NewState = State#state{players = NewPlayers},
            update_db(NewState),

            {reply, ok, NewState}
    end;

handle_call({buy_card, Username}, _From, State = #state{game_id = GameId, pot = Pot, status = waiting}) ->
    %% Transaction to check balance, deduct cost, and generate a card
    F = fun() ->
        [User] = mnesia:read(user, Username),
        CardsCount = length(mnesia:match_object(#card{user_id = Username, game_id = GameId, _ = '_'})),
        
        if 
            User#user.balance >= ?CARD_COST, CardsCount < ?MAX_CARDS ->
                NewBalance = User#user.balance - ?CARD_COST,
                mnesia:write(User#user{balance = NewBalance}),
                
                %% Generate a random 15-number tombola card (mocked logic for brevity)
                Numbers = lists:sublist(shuffle(lists:seq(1, 90)), 15),
                CardId = make_ref(),
                NewCard = #card{card_id = CardId, user_id = Username, game_id = GameId, grid = Numbers, combinations_won = []},
                mnesia:write(NewCard),
                io:format("[BUY] Player bought a card: ~p~n",[Username]),
                {ok, NewCard, NewBalance};
            CardsCount >= ?MAX_CARDS -> 
                io:format("[BUY] Player failed to buy a card due to max limit: ~p~n",[Username]),
                {error, max_cards_reached};
            true -> 
                io:format("[BUY] Player failed to buy a card due to insufficient funds: ~p~n",[Username]),
                {error, insufficient_funds}
        end
    end,
    case mnesia:transaction(F) of
        {atomic, {ok, Card, Balance}} -> 
            NewState = State#state{pot = Pot + ?CARD_COST},
            update_db(NewState),
            {reply, {ok, Card, Balance}, NewState};
        {atomic, Error} -> 
            {reply, Error, State}
    end;

handle_call({start_game, Username}, _From, State = #state{creator = Creator, status = waiting}) when Username =:= Creator ->
    %% Start the drawing loop
    Ref = erlang:send_after(?DRAW_INTERVAL, self(), draw_number),
    
    NewState = State#state{status = playing},
    update_db(NewState),
    
    %% Notify all players
    broadcast(State#state.players, {game_started, State#state.pot}),
    io:format("[START] Game started~n"),
    
    {reply, ok, State#state{status = playing, timer_ref = Ref}};

handle_call({claim_win, Username, Comb, CardId}, _From, State = #state{status = playing, won_combinations = Won, drawn = Drawn}) ->
    %% First-come, first-served logic for concurrent claims
    case lists:member(Comb, Won) of
        true -> 
            {reply, {error, already_claimed}, State};
        false ->
            %% Validate the claim against the database and extracted numbers
            case validate_win(Username, CardId, Comb, Drawn) of
                true ->
                    %% Payout logic (distribute the pot % based on combination)
                    Prize = calculate_prize(Comb, State#state.pot),
                    NewBalance = payout(Username, Prize),
                    
                    %% Broadcast the winner to everyone
                    broadcast(State#state.players, {winner, Username, Comb, Prize}),
                    
                    NewWon = [Comb | Won],
                    
                    %% If Tombola/Blackout, the game ends
                    if Comb =:= tombola ->
                        NewState = State#state{won_combinations = NewWon, status = finished},
                        update_db(NewState),
                        broadcast(State#state.players, game_over),
                        {stop, normal, {ok, Prize, NewBalance}, NewState};
                    true ->
                        NewState = State#state{won_combinations = NewWon},
                        update_db(NewState),
                        {reply, {ok, Prize, NewBalance}, NewState}
                    end;
                false ->
                    {reply, {error, invalid_claim}, State}
            end
    end;

handle_call({is_player_in_game, Username}, _From, State = #state{players = Players}) ->
    case lists:keyfind(Username, 1, Players) of
        false -> {reply, false, State};
        {_Username, _Pid} -> {reply, true, State}
    end;

handle_call({reconnect, Username, NewWsPid}, _From, State = #state{players = Players}) ->
    case lists:keyfind(Username, 1, Players) of
        false ->
            %% Il player non è nella partita → errore
            io:format("[RECONNECT] Non-Player tried to reconnect: ~p~n",[Username]),
            {reply, {error, not_in_game}, State};

        {_Username, OldWsPid} ->
            erlang:monitor(process, NewWsPid),

            %% Sostituisci il vecchio WS PID con quello nuovo
            NewPlayers = lists:keyreplace(Username, 1, Players, {Username, NewWsPid}),

            %% notifica riconnessione agli altri
            broadcast(NewPlayers, {user_reconnected, Username}),

            NewState = State#state{players = NewPlayers},
            update_db(NewState),

            io:format("[RECONNECT] Player correctly reconnected: ~p~n",[Username]),
            {reply, ok, NewState}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% The periodic number extraction loop
handle_info(draw_number, State = #state{status = playing, drawn = Drawn}) ->
    Available = lists:seq(1, 90) -- Drawn,
    case Available of
        [] -> 
            %% No more numbers
            {noreply, State};
        _ ->
            %% Pick a random number
            Num = lists:nth(rand:uniform(length(Available)), Available),
            NewDrawn = [Num | Drawn],
            
            %% Broadcast to clients via their Cowboy WebSockets
            broadcast(State#state.players, {number_drawn, Num}),

            NewState = State#state{drawn = NewDrawn},
            update_db(NewState),
            
            Ref = erlang:send_after(?DRAW_INTERVAL, self(), draw_number),
            {noreply, State#state{drawn = NewDrawn, timer_ref = Ref}}
    end;

handle_info({'DOWN', _Ref, process, DeadPid, _Reason}, State = #state{players = Players}) ->
    io:format("[DISCONNECT] Connection lost with player: ~p~n",[Username]),
    case lists:keyfind(DeadPid, 2, Players) of
        false ->
            %% Non era un player → ignora
            {noreply, State};

        {Username, DeadPid} ->
            io:format("Player ~p disconnesso (~p)~n", [Username, DeadPid]),

            NewPlayers = lists:keyreplace(Username, 1, Players, {Username, disconnected}),

            %% Notifica agli altri
            broadcast(NewPlayers, {user_disconnected, Username}),

            NewState = State#state{players = NewPlayers},
            update_db(NewState),

            {noreply, NewState}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State = #state{game_id = GameId}) ->
    io:format("Game server ~p terminated: ~p~n", [State#state.game_id, Reason]),

    %% Rimuove il registro globale
    case global:whereis_name(GameId) of
        undefined -> ok;   % già rimosso o mai registrato
        _Pid -> global:unregister_name(GameId)
    end,
    
    %% Se avevi timer attivi
    case State#state.timer_ref of
        undefined -> ok;
        Ref -> erlang:cancel_timer(Ref)
    end,

    %% Eventuali notifiche ai giocatori
    %% lists:foreach(fun({Username, WsPid}) ->
    %%                %% Puoi inviare un messaggio di chiusura WS
    %%                WsPid ! {game_terminated, State#state.game_id}
    %%            end, State#state.players),

    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% --- Internal Functions ---

broadcast(Players, Msg) ->
    %% Sends the Erlang message to the Cowboy WebSocket PIDs
    [WsPid ! {game_event, Msg} || {_User, WsPid} <- Players, is_pid(WsPid)].

shuffle(List) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- List])].

validate_win(_Username, _CardId, _Comb, _Drawn) ->
    %% TODO: Fetch card from Mnesia, intersect Card#card.grid with Drawn numbers,
    %% and verify if the user truly has the required combination.
    %% Returning true for now to illustrate the flow.
    true.

calculate_prize(ambo, Pot) -> erlang:trunc(Pot * 0.10);
calculate_prize(terno, Pot) -> erlang:trunc(Pot * 0.15);
calculate_prize(quaterna, Pot) -> erlang:trunc(Pot * 0.20);
calculate_prize(cinquina, Pot) -> erlang:trunc(Pot * 0.25);
calculate_prize(tombola, Pot) -> erlang:trunc(Pot * 0.30).

payout(Username, Amount) ->
    F = fun() ->
        [User] = mnesia:read(user, Username),
        NewBalance = User#user.balance + Amount,
        mnesia:write(User#user{balance = NewBalance}),
        NewBalance
    end,

    {atomic, Balance} = mnesia:transaction(F),
    Balance.

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

update_db(State) ->
    %% Costruiamo il record da salvare su DB prendendo i dati dallo Stato del server
    GameRecord = #game{
        game_id = State#state.game_id,
        creator = State#state.creator,
        status  = State#state.status,
        players = State#state.players,
        drawn_numbers = State#state.drawn,
        pot = State#state.pot,
        won_combinations = State#state.won_combinations
    },
    
    %% Scriviamo su Mnesia. Usiamo dirty_write perché è velocissimo in RAM
    %% e sovrascrive automaticamente il vecchio record con lo stesso game_id.
    mnesia:dirty_write(game, GameRecord).