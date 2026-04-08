-module(game_server).
-behaviour(gen_server).

-include("../include/bingo_records.hrl").

%% API
-export([start/2, join/3, buy_card/2, start_game/2, ready_to_play/2, claim_win/5, leave/2, reconnect/3]).

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

ready_to_play(GamePid, Username) ->
    gen_server:call(GamePid, {ready_to_play, Username}).

%% A player claims a winning combination (ambo, terno, etc.)
claim_win(GamePid, Username, Combination, CardId, Numbers) ->
    gen_server:call(GamePid, {claim_win, Username, Combination, CardId, Numbers}).

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

            broadcast(ExistingRecord#game.players, {game_recovered, self()}),

            %% Se la partita era 'playing' quando è crashata, facciamo ripartire il timer!
            FinalState = case RecoveredState#state.status of
                playing ->
                    Ref = erlang:send_after(?DRAW_INTERVAL, self(), draw_number),
                    RecoveredState#state{timer_ref = Ref};
                waiting ->
                    io:format("[RECOVERY] Waiting game ~p found without active process: atomically cleaning and refunding~n", [GameId]),
                    %% Cleanup atomico: previene race condition con main_server nodedown handler
                    cleanup_waiting_game_atomic(GameId),
                    stop_waiting_recovery;
                _ ->
                    RecoveredState
            end,

            case FinalState of
                stop_waiting_recovery ->
                    {stop, waiting_game_cancelled};
                _ ->
                    {ok, FinalState}
            end
    end.

handle_call({join, Username, WsPid}, _From, State = #state{status = waiting, players = Players, creator = Creator}) ->
    case lists:keyfind(Username, 1, Players) of
        false ->
            io:format("[JOIN] New player joined the game: ~p~n",[Username]),
            erlang:monitor(process, WsPid),
            broadcast(Players, {user_joined, Username}),
            %% Update state with new player and their WebSocket PID
            Ready = case Username of 
                        Creator -> ready;
                        _ -> not_ready
                    end,
            NewPlayers = [{Username, WsPid, Ready} | proplists:delete(Username, Players)],
            PlayerCount = length(NewPlayers),

            NewState = State#state{players = NewPlayers},
            update_db(NewState),

            {reply, {ok, PlayerCount}, NewState};
        {_Username, _OldPid, _Ready} ->
            %% Già presente
            io:format("[WARNING] Player already in game: ~p~n",[Username]),
            {reply, {error, player_already_in_game}, State}
    end;

handle_call({join, Username, _WsPid}, _From, State) ->
    io:format("[WARNING] Player tried to join game not in waiting room: ~p~n",[Username]),
    {reply, {error, game_already_started}, State};

handle_call({leave, Username}, _From, State = #state{creator = Creator, status = waiting, players = Players, game_id = GameId}) ->
    case lists:keyfind(Username, 1, Players) of
        false ->
            %% Non presente
            io:format("[WARNING] Player not in game tried to leave: ~p~n",[Username]),
            {reply, {error, player_not_in_game}, State};
        {_Username, _Pid, _Ready} ->
            NewBalance = remove_player_cards(Username, GameId, waiting),
            case NewBalance of
                {error, refund_failed} ->
                    {reply, {error, leave_failed}, State};
                _ ->
                    case Username =:= Creator of
                        true -> 
                            io:format("[LEAVE] Creator left unstarted game, game cancelled~n"),
                            NewPlayers = lists:filter(fun({U, _, _}) -> U =/= Username end, Players),

                            %% Rimuove/rimborsa le cartelle dei player rimanenti e notifica saldo aggiornato.
                            lists:foreach(
                                fun({PlayerUsername, PlayerWsPid, _PlayerReady}) ->
                                    PlayerBalance = remove_player_cards(PlayerUsername, GameId, waiting),
                                    case {is_pid(PlayerWsPid), PlayerBalance} of
                                        {true, {error, _}} ->
                                            PlayerWsPid ! {error, leave_failed};
                                        {true, _} ->
                                            PlayerWsPid ! {game_event, {game_cancelled, PlayerBalance}};
                                        _ ->
                                            ok
                                    end
                                end,
                                NewPlayers
                            ),

                            %% Il creatore lascia e la partita è in waiting → cancelliamo la partita
                            delete_game(GameId),

                            {stop, normal, {game_cancelled, NewBalance}, State};
                        _ -> 
                            %% Rimuovi il giocatore dalla lista (sia creatore dopo l'inizio del gioco sia giocatore normale)
                            io:format("[LEAVE] Player left the game in waiting room: ~p~n",[Username]),
                            NewPlayers = lists:filter(fun({U, _, _}) -> U =/= Username end, Players),
                            broadcast(NewPlayers, {user_left, Username}),
                            NewState = State#state{players = NewPlayers},
                            update_db(NewState),
                            {reply, {ok, NewBalance}, NewState}
                    end
            end
    end;

handle_call({leave, Username}, _From, State = #state{status = Status, players = Players, game_id = GameId}) ->
    case lists:keyfind(Username, 1, Players) of
        false ->
            %% Non presente
            io:format("[WARNING] Player not in game tried to leave: ~p~n",[Username]),
            {reply, {error, player_not_in_game}, State};
        {_Username, _Pid, _Ready} ->
            case remove_player_cards(Username, GameId, Status) of
                {error, refund_failed} ->
                    {reply, {error, leave_failed}, State};
                Balance ->
                    %% Rimuovi il giocatore dalla lista (sia creatore dopo l'inizio del gioco sia giocatore normale)
                    io:format("[LEAVE] Player left started game: ~p~n",[Username]),
                    NewPlayers = lists:filter(fun({U, _, _}) -> U =/= Username end, Players),
                    case NewPlayers of
                        [] ->
                            io:format("[LEAVE] Last player left, game cancelled~n"),
                            delete_game(GameId),
                            {stop, normal, {ok, Balance}, State};
                        _ ->
                            broadcast(NewPlayers, {user_left, Username}),
                            NewState = State#state{players = NewPlayers},
                            update_db(NewState),
                            {reply, {ok, Balance}, NewState}
                    end
            end
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
                
                %% Generate a tombola-style card: 3 rows x 5 numbers,
                %% with unique numbers per card and at most one number per decade per row.
                Numbers = generate_card_grid(),
                CardId = binary:encode_hex(crypto:strong_rand_bytes(8)),
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

handle_call({start_game, Username}, _From, State = #state{creator = Creator, players = Players, status = waiting}) when Username =:= Creator ->
    case lists:all(fun({_, _, R}) -> R =:= ready end, Players) of
        true -> 
            %% Start the drawing loop
            Ref = erlang:send_after(?DRAW_INTERVAL, self(), draw_number),
            
            NewState = State#state{status = playing},
            update_db(NewState),
            
            %% Notify all players
            broadcast(State#state.players, {game_started, State#state.pot}),
            io:format("[START] Game started~n"),
            
            {reply, ok, State#state{status = playing, timer_ref = Ref}};
        _ ->
            io:format("[WARNING] Not all users are ready: ~p~n",[Username]),
            {reply, {error, not_all_users_are_ready}, State}
    end;

handle_call({ready_to_play, Username}, _From, State = #state{creator = Creator, status = waiting, players = Players})  when Username =/= Creator->
    case lists:keyfind(Username, 1, Players) of
        false -> 
            io:format("[WARNING] User declared ready to play without being in game: ~p~n",[Username]),
            {reply, {error, not_in_game}, State};
        {_Username, OldWsPid, not_ready} ->
            %% Notify all players
            io:format("[READY] User is ready to play: ~p~n",[Username]),
            broadcast(State#state.players, {user_ready, Username}),
            NewPlayers = lists:keyreplace(Username, 1, Players, {Username, OldWsPid, ready}),
            NewState = State#state{players = NewPlayers},
            update_db(NewState),
            case lists:all(fun({_, _, R}) -> R =:= ready end, NewPlayers) of
                true -> broadcast(NewPlayers, all_ready);
                _ -> ok
            end,
            {reply, ok, NewState};
        {_Username, _OldWsPid, ready} ->
            io:format("[WARNING] User declared ready to play when already ready: ~p~n",[Username]),
            {reply, {error, already_ready}, State}
    end;

handle_call({claim_win, Username, Comb, CardId, Numbers}, _From, State = #state{status = playing, won_combinations = Won, drawn = Drawn, game_id = GameId}) ->
    %% First-come, first-served logic for concurrent claims
    case lists:member(Comb, Won) of
        true -> 
            {reply, {error, already_claimed}, State};
        false ->
            %% Validate the claim against the database and extracted numbers
            case validate_win(Username, GameId, CardId, Comb, Drawn, Numbers) of
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
                        {reply, {ok, Prize, NewBalance}, NewState};
                    true ->
                        NewState = State#state{won_combinations = NewWon},
                        update_db(NewState),
                        {reply, {ok, Prize, NewBalance}, NewState}
                    end;
                false ->
                    {reply, {error, invalid_claim}, State}
            end
    end;

handle_call({claim_win, Username, _Comb, _CardId, _Numbers}, _From, State = #state{status = finished}) ->
    io:format("[WARNING] Player tried to claim a winning combination after game finished: ~p~n",[Username]),
    {reply, {error, game_already_finished}, State};

handle_call({reconnect, Username, NewWsPid}, _From, State = #state{status = playing, players = Players, game_id = GameId, drawn = Drawn, won_combinations = Won}) ->
    case lists:keyfind(Username, 1, Players) of
        false ->
            %% Il player non è nella partita → errore
            io:format("[WARNING] Player not in the game tried to reconnect: ~p~n",[Username]),
            {reply, {error, player_not_in_game}, State};

        {_Username, _OldWsPid, Ready} ->
            erlang:monitor(process, NewWsPid),

            %% Sostituisci il vecchio WS PID con quello nuovo
            NewPlayers = lists:keyreplace(Username, 1, Players, {Username, NewWsPid, Ready}),
            PlayerCount = length(NewPlayers),

            %% notifica riconnessione agli altri
            broadcast(NewPlayers, {user_reconnected, Username}),

            NewState = State#state{players = NewPlayers},
            update_db(NewState),

            %% 1. Recupero le cartelle da Mnesia tramite pattern matching
            Pattern = #card{user_id = Username, game_id = GameId, _ = '_'},
            UserCardsRecords = mnesia:dirty_match_object(card, Pattern),
            %% Ritorna una lista JSON-safe di card per ws_handler/restore_game.
            UserCards = [
                #{
                    <<"grid">> => Card#card.grid,
                    <<"card_id">> => Card#card.card_id
                }
                || Card <- UserCardsRecords
            ],

            io:format("[RECONNECT] Player correctly reconnected: ~p~n",[Username]),
            
            %% Ritorniamo tutto al chiamante (ws_handler) al posto del semplice 'ok'
            {reply, {ok, UserCards, Drawn, Won, PlayerCount}, NewState}
    end;

handle_call({reconnect, Username, _NewWsPid}, _From, State = #state{status = waiting}) ->
    io:format("[WARNING] Player tried to reconnect to a game in waiting room: ~p~n",[Username]),
    {reply, {error, game_not_started}, State};

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

handle_info({'DOWN', _Ref, process, DeadPid, _Reason}, State = #state{status = waiting, players = Players, creator = Creator, game_id = GameId}) ->
    case lists:keyfind(DeadPid, 2, Players) of
        false ->
            %% Non era un player → ignora
            {noreply, State};

        {Username, DeadPid, _Ready} ->
            remove_player_cards(Username, GameId, waiting),
            case Username =:= Creator of
                true -> 
                    io:format("[LEAVE] Creator left unstarted game, game cancelled~n"),
                    NewPlayers = lists:filter(fun({U, _, _}) -> U =/= Username end, Players),

                    %% Rimuove/rimborsa le cartelle dei player rimanenti e notifica saldo aggiornato.
                    lists:foreach(
                        fun({PlayerUsername, PlayerWsPid, _PlayerReady}) ->
                            PlayerBalance = remove_player_cards(PlayerUsername, GameId, waiting),
                            case {is_pid(PlayerWsPid), PlayerBalance} of
                                {true, {error, _}} ->
                                    PlayerWsPid ! {error, leave_failed};
                                {true, _} ->
                                    PlayerWsPid ! {game_event, {game_cancelled, PlayerBalance}};
                                _ ->
                                    ok
                            end
                        end,
                        NewPlayers
                    ),

                    %% Il creatore lascia e la partita è in waiting → cancelliamo la partita
                    delete_game(GameId),
                    {stop, normal, State};
                _ ->
                    io:format("Player disconnected from the game waiting room: ~p~n", [Username]),

                    NewPlayers = lists:filter(fun({U, _, _}) -> U =/= Username end, Players),
                    case NewPlayers of
                        [] ->
                            io:format("[LEAVE] Last player left, game cancelled~n"),
                            delete_game(GameId),
                            {stop, normal, State};
                        _ ->
                            %% Notifica agli altri
                            broadcast(NewPlayers, {user_left, Username}),
                            NewState = State#state{players = NewPlayers},
                            update_db(NewState),
                            {noreply, NewState}
                    end
            end
    end;

handle_info({'DOWN', _Ref, process, DeadPid, _Reason}, State = #state{status = playing, players = Players}) ->
    case lists:keyfind(DeadPid, 2, Players) of
        false ->
            %% Non era un player → ignora
            {noreply, State};

        {Username, DeadPid, Ready} ->
            io:format("Player ~p disconnesso (~p)~n", [Username, DeadPid]),

            NewPlayers = lists:keyreplace(Username, 1, Players, {Username, disconnected, Ready}),

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

    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% --- Internal Functions ---

broadcast(Players, Msg) ->
    %% Sends the Erlang message to the Cowboy WebSocket PIDs
    [WsPid ! {game_event, Msg} || {_User, WsPid, _Ready} <- Players, is_pid(WsPid)].


shuffle(List) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- List])].

generate_card_grid() ->
    generate_card_rows(3, [], []).

generate_card_rows(0, Acc, _UsedNumbers) ->
    lists:flatten(lists:reverse(Acc));
generate_card_rows(N, Acc, UsedNumbers) ->
    {Row, NextUsedNumbers} = generate_card_row(UsedNumbers),
    generate_card_rows(N - 1, [Row | Acc], NextUsedNumbers).

generate_card_row(UsedNumbers) ->
    Decades = lists:sublist(shuffle(lists:seq(1, 9)), 5),
    RowNumbers = [pick_number_from_decade(Decade, UsedNumbers) || Decade <- Decades],
    {RowNumbers, RowNumbers ++ UsedNumbers}.

pick_number_from_decade(Decade, UsedNumbers) ->
    AvailableNumbers = [Number || Number <- decade_numbers(Decade), not lists:member(Number, UsedNumbers)],
    lists:nth(rand:uniform(length(AvailableNumbers)), AvailableNumbers).

decade_numbers(9) -> lists:seq(80, 90);
decade_numbers(1) -> lists:seq(1, 9);
decade_numbers(Decade) ->
    Start = (Decade - 1) * 10,
    lists:seq(Start, Start + 9).

validate_win(Username, GameId, CardId, Comb, Drawn, Numbers) ->
    Pattern = #card{card_id = CardId, user_id = Username, game_id = GameId, _ = '_'},
    case mnesia:dirty_match_object(card, Pattern) of
        [] ->
            false;
        [Card] ->
            case Numbers of
                [] ->
                    false;
                _ ->
                    CardGrid = Card#card.grid,
                    DrawnSet = sets:from_list(Drawn),
                    lists:all(
                        fun(N) ->
                            lists:member(N, CardGrid) andalso sets:is_element(N, DrawnSet)
                        end,
                        Numbers
                    ) andalso selection_respects_combination(Comb, CardGrid, Numbers)
            end
    end.

selection_respects_combination(tombola, _CardGrid, SelectedNumbers) ->
    length(SelectedNumbers) >= 15;
selection_respects_combination(Comb, CardGrid, SelectedNumbers) ->
    RequiredHits = comb_to_hits(Comb),
    case RequiredHits of
        0 ->
            false;
        _ ->
            Rows = [
                lists:sublist(CardGrid, 5),
                lists:sublist(lists:nthtail(5, CardGrid), 5),
                lists:sublist(lists:nthtail(10, CardGrid), 5)
            ],
            length(SelectedNumbers) >= RequiredHits andalso
            lists:any(
                fun(Row) ->
                    lists:all(fun(N) -> lists:member(N, Row) end, SelectedNumbers)
                end,
                Rows
            )
    end.

comb_to_hits(ambo) -> 2;
comb_to_hits(terno) -> 3;
comb_to_hits(quaterna) -> 4;
comb_to_hits(cinquina) -> 5;
comb_to_hits(tombola) -> 15;
comb_to_hits(_) -> 0.

calculate_prize(ambo, Pot) -> erlang:trunc(Pot * 0.10);
calculate_prize(terno, Pot) -> erlang:trunc(Pot * 0.15);
calculate_prize(quaterna, Pot) -> erlang:trunc(Pot * 0.20);
calculate_prize(cinquina, Pot) -> erlang:trunc(Pot * 0.25);
calculate_prize(tombola, Pot) ->
    Pot
    - calculate_prize(ambo, Pot)
    - calculate_prize(terno, Pot)
    - calculate_prize(quaterna, Pot)
    - calculate_prize(cinquina, Pot).

payout(Username, Amount) ->
    F = fun() ->
        [User] = mnesia:read(user, Username),
        NewBalance = User#user.balance + Amount,
        mnesia:write(User#user{balance = NewBalance}),
        NewBalance
    end,

    {atomic, Balance} = mnesia:transaction(F),
    Balance.

%% Funzione per contare quante cartelle ha comprato un giocatore e calcolare il rimborso totale
%% e rimuovere le cartelle dal database
remove_player_cards(Username, GameId, Status) ->
    Pattern = #card{user_id = Username, game_id = GameId, _ = '_'},
    Cards = mnesia:dirty_match_object(card, Pattern),
    Refund = length(Cards) * ?CARD_COST,
    lists:foreach(
        fun(Card) ->
            mnesia:dirty_delete_object(Card)
        end,
        Cards
    ),
    case Status of
        waiting ->
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
            end;
        _ ->
            atom_to_binary(balance_unchanged, utf8)
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
                {ok, Notifications}
        end
    end,
    
    case mnesia:transaction(F) of
        {atomic, {ok, Notifications}} ->
            lists:foreach(
                fun({PlayerWsPid, PlayerBalance}) ->
                    PlayerWsPid ! {game_event, {game_cancelled, PlayerBalance}}
                end,
                Notifications
            ),
            io:format("[CLEANUP] Partita ~p ripulita atomicamente~n", [GameId]),
            ok;
        {aborted, Reason} ->
            io:format("[CLEANUP] Errore nella cleanup atomica di ~p: ~p~n", [GameId, Reason]),
            {error, Reason}
    end.