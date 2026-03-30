-module(bingo_app).
-export([start/1]). %% Ora accetta la porta come parametro!

start(Port) ->
    %% Assicuriamoci che Cowboy e dipendenze siano avviati
    application:ensure_all_started(cowboy),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/api/register", http_handler, [register]},
            {"/api/login", http_handler, [login]},
            {"/ws", ws_handler, []}
        ]}
    ]),

    %% Usa la porta passata come parametro
    {ok, _} = cowboy:start_clear(list_to_atom("bingo_listener_" ++ integer_to_list(Port)),
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),
    
    io:format("~n[INFO] Server avviato sulla porta ~p!~n", [Port]).