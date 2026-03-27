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
    Password = binary_to_list(maps:get(<<"password">>, Decoded)),

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
                Hash = erlang:md5(Password), %% Simple hash for demo purposes
                NewUser = #user{username = Username, password_hash = Hash, balance = 100},
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
                Hash = erlang:md5(Password),
                if User#user.password_hash =:= Hash ->
                    #{<<"status">> => <<"ok">>, <<"balance">> => User#user.balance};
                true ->
                    #{<<"status">> => <<"error">>, <<"message">> => <<"wrong_password">>}
                end;
            [] ->
                #{<<"status">> => <<"error">>, <<"message">> => <<"user_not_found">>}
        end
    end,
    {atomic, Result} = mnesia:transaction(F),
    Result.