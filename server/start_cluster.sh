#!/bin/bash

COOKIE="bingo_secret_cookie"

PATHS="-pa ebin/ -pa deps/jsx/ebin -pa deps/cowboy/ebin -pa deps/cowboy/deps/cowlib/ebin -pa deps/cowboy/deps/ranch/ebin"

erl -sname node1@localhost -setcookie $COOKIE $PATHS -eval "bingo_app:start(8081)." -detached

erl -sname node2@localhost -setcookie $COOKIE $PATHS -eval "bingo_app:start(8082)." -detached

sleep 2

erl -sname main_node@localhost -setcookie $COOKIE $PATHS -eval "main_server:start_link(['node1@localhost', 'node2@localhost'])." -noshell &
