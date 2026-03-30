-module(http_handler).
-behaviour(cowboy_handler).

-export([init/2]).
-include("../include/bingo_records.hrl").

init(Req0, State) ->
    %% Read the action from the state passed by the router (register | login)
    Action = hd(State),
    
    %% Read the request body
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    
    %% Parse JSON (assuming jsx library)
    %% Expected format: {"username": "foo", "password": "bar"}
    Decoded = jsx:decode(Body, [return_maps]),
    Username = binary_to_list(maps:get(<<"username">>, Decoded)),
    Password = maps:get(<<"password">>, Decoded),

    Response = handle_auth(Action, Username, Password),
    
    %% Send JSON response
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Response),
        Req1
    ),
    {ok, Req2, State}.

handle_auth(register, Username, Password) ->
    F = fun() ->
        case mnesia:read(user, Username) of
            [] -> 
                %% Hash password and give initial balance (e.g., 100 coins)
                {Hash, Salt} = hash_password(Password),
                NewUser = #user{username = Username, password_hash = Hash, salt = Salt, balance = 100},
                mnesia:write(NewUser),
                #{<<"status">> => <<"ok">>, <<"message">> => <<"registered">>};
            [_Existing] ->
                #{<<"status">> => <<"error">>, <<"message">> => <<"user_exists">>}
        end
    end,
    {atomic, Result} = mnesia:transaction(F),
    Result;

handle_auth(login, Username, Password) ->
    F = fun() ->
        case mnesia:read(user, Username) of
            [User] -> 
                %% Chiamiamo verify_password estraendo hash e salt direttamente dal record
                case verify_password(Password, User#user.password_hash, User#user.salt) of
                    true ->
                        #{<<"status">> => <<"ok">>, <<"balance">> => User#user.balance};
                    false ->
                        #{<<"status">> => <<"error">>, <<"message">> => <<"wrong_password">>}
                end;
            [] ->
                #{<<"status">> => <<"error">>, <<"message">> => <<"user_not_found">>}
        end
    end,
    {atomic, Result} = mnesia:transaction(F),
    Result.

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