-module(db_manager).
-export([init_cluster_db/1, cleanup_cluster_db/1]).
-include("../include/bingo_records.hrl").

init_cluster_db(Nodes) ->
    %% Ensure Mnesia is stopped on all nodes before creating the schema
    rpc:multicall(Nodes, mnesia, stop, []),
    
    %% Creating distributed schema on provided nodes
    case mnesia:create_schema(Nodes) of
        ok -> io:format("Mnesia schema successfully created on nodes: ~p~n", [Nodes]);
        {error, {Node, {already_exists, Node}}} -> io:format("Mnesia schema already exists.~n")
    end,

    %% Starting Mnesia on all nodes
    rpc:multicall(Nodes, mnesia, start, []),

    %% Creating replicated tables
    mnesia:create_table(user, [
        {attributes, record_info(fields, user)},
        {disc_copies, Nodes}
    ]),

    mnesia:create_table(session, [
        {attributes, record_info(fields, session)},
        {ram_copies, Nodes}
    ]),
    
    mnesia:create_table(game, [
        {attributes, record_info(fields, game)},
        {ram_copies, Nodes}
    ]),
    
    mnesia:create_table(card, [
        {attributes, record_info(fields, card)},
        {ram_copies, Nodes}
    ]),

    %% Waiting for tables to be ready and synchronized
    mnesia:wait_for_tables([user, game, card], 5000),
    io:format("Mnesia database initialized and tables ready.~n").

cleanup_cluster_db(Nodes) ->
    %% Stop Mnesia on all nodes
    rpc:multicall(Nodes, mnesia, stop, []),
    ok.