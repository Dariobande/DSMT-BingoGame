%% include/bingo_records.hrl

%% Tabella Utenti
-record(user, {
    username,       %% Chiave primaria
    password_hash,  %% Password criptata
    salt,
    balance         %% Denaro in-game
}).

-record(session, {token, username, game_id, last_active}).

%% Tabella Partite
-record(game, {
    game_id,         %% Chiave primaria (es. UUID o stringa)
    creator,         %% Username di chi ha creato la partita
    status,          %% 'waiting' (attesa inizio), 'playing' (in corso), 'finished' (terminata)
    drawn_numbers,   %% Lista dei numeri già estratti
    pot,             %% Montepremi totale
    players,         %% Lista degli username partecipanti
    won_combinations %% Lista di combinazioni già reclamate (es. [{username, ambo}, {username, terno}]) per evitare doppi reclami
}).

%% Tabella Cartelle
-record(card, {
    card_id,          %% Chiave primaria univoca
    user_id,          %% Proprietario della cartella
    game_id,          %% Partita di riferimento
    grid,             %% Lista di numeri (es. 15 numeri per la tombola)
    combinations_won  %% Lista delle combinazioni già reclamate (es. [ambo, terno]) per evitare doppi reclami
}).