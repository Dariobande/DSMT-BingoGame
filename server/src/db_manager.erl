-module(db_manager).
-export([init_cluster_db/1]).
-include("../include/bingo_records.hrl").

init_cluster_db(Nodes) ->
    %% Assicuriamoci che Mnesia sia fermo su tutti i nodi prima di creare lo schema
    rpc:multicall(Nodes, mnesia, stop, []),
    
    %% Creazione dello schema distribuito sui nodi forniti
    case mnesia:create_schema(Nodes) of
        ok -> io:format("Schema Mnesia creato con successo sui nodi: ~p~n", [Nodes]);
        {error, {Node, {already_exists, Node}}} -> io:format("Schema Mnesia gia' esistente.~n")
    end,

    %% Avvio di Mnesia su tutti i nodi
    rpc:multicall(Nodes, mnesia, start, []),

    %% Creazione delle tabelle replicate
    mnesia:create_table(user, [
        {attributes, record_info(fields, user)},
        {disc_copies, Nodes}
    ]),
    
    mnesia:create_table(game, [
        {attributes, record_info(fields, game)},
        {disc_copies, Nodes}
    ]),
    
    mnesia:create_table(card, [
        {attributes, record_info(fields, card)},
        {disc_copies, Nodes}
    ]),

    %% Attesa che le tabelle siano pronte e sincronizzate
    mnesia:wait_for_tables([user, game, card], 5000),
    io:format("Database Mnesia inizializzato e tabelle pronte.~n").