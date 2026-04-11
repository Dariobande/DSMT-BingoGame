-module(http_handler).
-behaviour(cowboy_handler).

-export([init/2]).
-include("../include/bingo_records.hrl").

init(Req0, State) ->
    io:format("[CONNECTION] New client connection~n"),

    %% Read cookies
    CookiesList = cowboy_req:parse_cookies(Req0),
    Cookies = maps:from_list(CookiesList),

    %% Read the action from the router (register | login)
    Action = hd(State),
    
    %% Read the request body
    {ok, Body, Req1} = cowboy_req:read_body(Req0),

    %% Handle login/register
    {Response, MaybeSetCookie} = handle_auth(Action, Body, Cookies),

    %% Send JSON response, optionally setting the cookie
    Req2 = case MaybeSetCookie of
        undefined ->
            %% No cookie to set
            cowboy_req:reply(200,
                #{<<"content-type">> => <<"application/json">>},
                jsx:encode(Response),
                Req1
            );
        {session_token, TokenB64} ->
            ReqWithCookie = cowboy_req:set_resp_cookie(
                <<"session_token">>, 
                TokenB64, 
                Req1, 
                #{path => <<"/">>, http_only => true}
            ),
            cowboy_req:reply(200,
                #{<<"content-type">> => <<"application/json">>},
                jsx:encode(Response),
                ReqWithCookie
            )
    end,

    {ok, Req2, State}.

handle_auth(register, Body, _Cookies) ->
    Decoded = jsx:decode(Body, [return_maps]),
    Username = binary_to_list(maps:get(<<"username">>, Decoded)),
    Password = maps:get(<<"password">>, Decoded),
    ConfirmPassword = maps:get(<<"confirm_password">>, Decoded),

    case Password =:= ConfirmPassword of
        false ->
            io:format("[REGISTRATION] Registration failed, passwords do not match~n"),
            {#{<<"status">> => <<"error">>, <<"message">> => <<"passwords_do_not_match">>}, undefined};
        true ->
            F = fun() ->
                case mnesia:read(user, Username) of
                    [] ->
                        {Hash, Salt} = hash_password(Password),
                        NewUser = #user{
                            username = Username,
                            password_hash = Hash,
                            salt = Salt,
                            balance = 100
                        },
                        mnesia:write(NewUser),
                        io:format("[REGISTRATION] New account correctly registered: ~p~n",[Username]),
                        {#{<<"status">> => <<"ok">>, <<"message">> => <<"registered">>}, undefined};
                    [_Existing] ->
                        io:format("[REGISTRATION] Registration failed, username already exists: ~p~n",[Username]),
                        {#{<<"status">> => <<"error">>, <<"message">> => <<"user_exists">>}, undefined}
                end
            end,
            {atomic, {Response, MaybeSetCookie}} = mnesia:transaction(F),
            {Response, MaybeSetCookie}
    end;

handle_auth(login, Body, Cookies) ->
    SessionToken = maps:get(<<"session_token">>, Cookies, undefined),

    Decoded = jsx:decode(Body, [return_maps]),
    Username = binary_to_list(maps:get(<<"username">>, Decoded)),
    Password = maps:get(<<"password">>, Decoded),

    F = fun() ->
        case mnesia:read(user, Username) of
            [User] ->
                case verify_password(Password, User#user.password_hash, User#user.salt) of
                    true ->
                        case SessionToken of
                            Token when is_binary(Token) ->
                                case mnesia:read({session, Token}) of
                                    [#session{game_id = GameID}] ->
                                        %% Valid token, return game_id if present
                                        io:format("[LOGIN] Login successful: ~p~n",[Username]),
                                        Response = #{<<"status">> => <<"ok">>,
                                                     <<"balance">> => User#user.balance,
                                                     <<"game_id">> => GameID},
                                        {Response, undefined};
                                    [] ->
                                        %% Invalid token → generate new token
                                        NewTokenB64 = gen_new_token(Username),
                                        io:format("[LOGIN] Login successful: ~p~n",[Username]),
                                        Response = #{<<"status">> => <<"ok">>,
                                                     <<"balance">> => User#user.balance},
                                        {Response, {session_token, NewTokenB64}}
                                end;
                            _ ->
                                %% No token → generate new token
                                NewTokenB64 = gen_new_token(Username),
                                io:format("[LOGIN] Login successful: ~p~n",[Username]),
                                Response = #{<<"status">> => <<"ok">>,
                                             <<"balance">> => User#user.balance},
                                {Response, {session_token, NewTokenB64}}
                        end;
                    false ->
                        io:format("[LOGIN] Login authentication failed: ~p~n",[Username]),
                        {#{<<"status">> => <<"error">>, <<"message">> => <<"wrong_password">>}, undefined}
                end;
            [] ->
                io:format("[LOGIN] Login authentication failed: ~p~n",[Username]),
                {#{<<"status">> => <<"error">>, <<"message">> => <<"user_not_found">>}, undefined}
        end
    end,

    {atomic, {Response, MaybeSetCookie}} = mnesia:transaction(F),
    {Response, MaybeSetCookie}.

gen_new_token(Username) ->
    TokenBin = crypto:strong_rand_bytes(16),
    TokenB64 = base64:encode(TokenBin),
    Now = erlang:system_time(second),
    mnesia:write(#session{token = TokenB64, username = Username, game_id = undefined, last_active = Now}),
    TokenB64.

%% Generate a new Salt and calculate the PBKDF2 hash of the password
hash_password(Password) when is_binary(Password) ->
    Salt = crypto:strong_rand_bytes(16),
    Iterations = 10000,
    KeyLength = 32,
    Hash = crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, KeyLength),
    {base64:encode(Hash), base64:encode(Salt)}.

%% Verify if the entered password, combined with the saved Salt, produces the saved hash
verify_password(PasswordInserted, SavedHash, SavedSalt) when is_binary(PasswordInserted) ->
    SaltBinary = base64:decode(SavedSalt),
    Iterations = 10000,
    KeyLength = 32,
    ComputedHash = crypto:pbkdf2_hmac(sha256, PasswordInserted, SaltBinary, Iterations, KeyLength),
    %% If the calculated hash is now identical to the one in the database, the password is correct
    base64:encode(ComputedHash) =:= SavedHash.