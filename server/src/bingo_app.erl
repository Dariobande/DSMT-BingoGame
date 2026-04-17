-module(bingo_app).
-export([start/1, start/2]).

start(Port) ->
    start(Port, "localhost").

start(Port, MainServerHost) ->
    %% Ensure Cowboy and dependencies are started
    io:format("[INFO] Server initialization...~n"),
    application:ensure_all_started(cowboy),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/api/register", http_handler, [register]},
            {"/api/login", http_handler, [login]},
            {"/ws", ws_handler, []}
        ]}
    ]),

    {ok, _} = cowboy:start_clear(list_to_atom("bingo_listener_" ++ integer_to_list(Port)),
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),

    MainNode = list_to_atom("main_node@" ++ MainServerHost),
    case net_adm:ping(MainNode) of
        pong ->
            io:format("[INFO] Connected to the main server.~n");
        pang ->
            io:format("[WARNING] Error during main server connection.~n")
    end,
    
    io:format("[INFO] Server correctly started on port ~p!~n", [Port]).