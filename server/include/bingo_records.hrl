%% include/bingo_records.hrl

%% User Table
-record(user, {
    username,       %% Primary key
    password_hash,  %% Encrypted password
    salt,
    balance         %% In-game money
}).

-record(session, {token, username, game_id, last_active}).

%% Game Table
-record(game, {
    game_id,         %% Primary key (e.g. UUID or string)
    creator,         %% Username of who created the game
    status,          %% 'waiting' (waiting to start), 'playing' (in progress), 'finished' (finished)
    drawn_numbers,   %% List of already drawn numbers
    pot,             %% Total pot
    players,         %% List of participating usernames
    won_combinations %% List of already claimed combinations (e.g. [ambo, terno...]) to prevent double claims
}).

%% Card Table
-record(card, {
    card_id,          %% Unique primary key
    user_id,          %% Card owner
    game_id,          %% Referenced game
    grid             %% List of numbers (e.g. 15 numbers for bingo)
}).