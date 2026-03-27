-module(bingo_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    %% Define routing for Cowboy
    %% We route HTTP requests to http_handler and WebSocket connections to ws_handler
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/api/register", http_handler, [register]},
            {"/api/login", http_handler, [login]},
            {"/ws", ws_handler, []}
        ]}
    ]),

    %% Start Cowboy listener on port 8080 (Nginx will proxy traffic here)
    {ok, _} = cowboy:start_clear(bingo_http_listener,
        [{port, 8080}],
        #{env => #{dispatch => Dispatch}}
    ),
    
    %% Start the top-level supervisor (assuming bingo_sup is implemented)
    bingo_sup:start_link().

stop(_State) ->
    ok.