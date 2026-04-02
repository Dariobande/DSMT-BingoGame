-module(http_handler).
-behaviour(cowboy_handler).

-export([init/2]).
-include("../include/bingo_records.hrl").

init(Req0, State) ->
    io:format("[CONNECTION] New client connection~n"),

    %% Legge i cookie
    Cookies = cowboy_req:cookies(Req0),

    %% Legge l'azione dal router (register | login)
    Action = hd(State),
    
    %% Legge il corpo della richiesta
    {ok, Body, Req1} = cowboy_req:read_body(Req0),

    %% Gestione login/register
    {Response, MaybeSetCookie} = handle_auth(Action, Body, Cookies),

    %% Invia la risposta JSON, eventualmente impostando il cookie
    Req2 = case MaybeSetCookie of
        undefined ->
            %% Nessun cookie da impostare
            cowboy_req:reply(200,
                #{<<"content-type">> => <<"application/json">>},
                jsx:encode(Response),
                Req1
            );
        {session_token, TokenB64} ->
            %% Imposta il cookie HttpOnly
            cowboy_req:set_resp_cookie(<<"session_token">>, TokenB64,
                #{path => <<"/">>, http_only => true}, 
                cowboy_req:reply(200,
                    #{<<"content-type">> => <<"application/json">>},
                    jsx:encode(Response),
                    Req1
                )
            )
    end,

    {ok, Req2, State}.

handle_auth(register, Body, _Cookies) ->
    %% Decodifica JSON
    Decoded = jsx:decode(Body, [return_maps]),
    Username = binary_to_list(maps:get(<<"username">>, Decoded)),
    Password = maps:get(<<"password">>, Decoded),
    ConfirmPassword = maps:get(<<"confirm_password">>, Decoded),

    %% Controlla che password e confirm_password coincidano
    case Password =:= ConfirmPassword of
        false ->
            io:format("[REGISTRATION] Registration failed, passwords do not match~n"),
            {{<<"status">> => <<"error">>, <<"message">> => <<"passwords_do_not_match">>}, undefined};
        true ->
            %% Procedi con Mnesia
            F = fun() ->
                case mnesia:read(user, Username) of
                    [] -> 
                        %% Hash password e saldo iniziale
                        {Hash, Salt} = hash_password(Password),
                        NewUser = #user{
                            username = Username,
                            password_hash = Hash,
                            salt = Salt,
                            balance = 100
                        },
                        mnesia:write(NewUser),
                        io:format("[REGISTRATION] New account correctly registered: ~p~n",[Username]),
                        {{<<"status">> => <<"ok">>, <<"message">> => <<"registered">>}, undefined};
                    [_Existing] ->
                        io:format("[REGISTRATION] Registration failed, username already exists: ~p~n",[Username]),
                        {{<<"status">> => <<"error">>, <<"message">> => <<"user_exists">>}, undefined}
                end
            end,
            {atomic, {Response, MaybeSetCookie}} = mnesia:transaction(F),
            {Response, MaybeSetCookie}
    end.

handle_auth(login, Body, Cookies) ->
    SessionToken = maps:get(<<"session_token">>, Cookies, undefined),

    %% Decodifica JSON
    Decoded = jsx:decode(Body, [return_maps]),
    Username = binary_to_list(maps:get(<<"username">>, Decoded)),
    Password = maps:get(<<"password">>, Decoded),

    F = fun() ->
        case mnesia:read(user, Username) of
            [User] ->
                case verify_password(Password, User#user.password_hash, User#user.salt) of
                    true ->
                        %% Se il token esiste ed è valido in DB
                        case SessionToken of
                            Token when is_binary(Token) ->
                                case mnesia:read({session, Token}) of
                                    [#session{game_id = GameID}] ->
                                        %% Token valido, restituisci game_id se presente
                                        io:format("[LOGIN] Login successful: ~p~n",[Username]),
                                        Response = #{<<"status">> => <<"ok">>,
                                                     <<"balance">> => User#user.balance,
                                                     <<"token">> => Token,
                                                     <<"game_id">> => GameID},
                                        {Response, undefined};
                                    [] ->
                                        %% Token non valido → genera nuovo token
                                        NewTokenB64 = gen_new_token(Username),
                                        io:format("[LOGIN] Login successful: ~p~n",[Username]),
                                        Response = #{<<"status">> => <<"ok">>,
                                                     <<"balance">> => User#user.balance,
                                                     <<"token">> => NewTokenB64},
                                        {Response, {session_token, NewTokenB64}}
                                end;
                            _ ->
                                %% Nessun token → genera nuovo token
                                NewTokenB64 = gen_new_token(Username),
                                io:format("[LOGIN] Login successful: ~p~n",[Username]),
                                Response = #{<<"status">> => <<"ok">>,
                                             <<"balance">> => User#user.balance,
                                             <<"token">> => NewTokenB64},
                                {Response, {session_token, NewTokenB64}}
                        end;
                    false ->
                        io:format("[LOGIN] Login authentication failed: ~p~n",[Username]),
                        {{<<"status">> => <<"error">>, <<"message">> => <<"wrong_password">>}, undefined}
                end;
            [] ->
                {{<<"status">> => <<"error">>, <<"message">> => <<"user_not_found">>}, undefined}
        end
    end,

    {atomic, {Response, MaybeSetCookie}} = mnesia:transaction(F),
    {Response, MaybeSetCookie}.

%% Funzione helper per generare un nuovo token e scrivere sessione
gen_new_token(Username) ->
    TokenBin = crypto:strong_rand_bytes(16),
    TokenB64 = base64:encode(TokenBin),
    Now = erlang:system_time(second),
    mnesia:write(#session{token = TokenB64, username = Username, game_id = undefined, last_active = Now}),
    TokenB64.

%% Genera un nuovo Salt e calcola l'hash PBKDF2 della password
hash_password(Password) when is_binary(Password) ->
    Salt = crypto:strong_rand_bytes(16),
    Iterazioni = 10000,
    LunghezzaChiave = 32,
    HashBinario = crypto:pbkdf2_hmac(sha256, Password, Salt, Iterazioni, LunghezzaChiave),
    %% Restituisce una tupla con Hash e Salt codificati in Base64 per salvarli facilmente nel DB
    {base64:encode(HashBinario), base64:encode(Salt)}.

%% Verifica se la password inserita, combinata col Salt salvato, produce l'hash salvato
verify_password(PasswordInserita, HashSalvatoB64, SaltSalvatoB64) when is_binary(PasswordInserita) ->
    SaltBinario = base64:decode(SaltSalvatoB64),
    Iterazioni = 10000,
    LunghezzaChiave = 32,
    HashCalcolato = crypto:pbkdf2_hmac(sha256, PasswordInserita, SaltBinario, Iterazioni, LunghezzaChiave),
    %% Se l'hash calcolato ora è identico a quello nel database, la password è corretta
    base64:encode(HashCalcolato) =:= HashSalvatoB64.