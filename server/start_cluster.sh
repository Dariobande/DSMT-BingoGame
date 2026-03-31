#!/bin/bash

# start_cluster.sh
# Assicurati di renderlo eseguibile lanciando da terminale: chmod +x start_cluster.sh

COOKIE="bingo_secret_cookie"

# Centralizziamo tutti i path delle librerie compilate per avere un comando pulito
PATHS="-pa ebin/ -pa deps/jsx/ebin -pa deps/cowboy/ebin -pa deps/cowboy/deps/cowlib/ebin -pa deps/cowboy/deps/ranch/ebin"

echo "Avvio del cluster Erlang per il Bingo Distribuito..."
echo "Compilazione in corso (assicurati di aver lanciato erlc prima)..."

# 1. Avvio dei nodi Cowboy in modalità detached (demoni in background)
# Chiamiamo la nostra funzione custom passando la porta specifica per ogni nodo
echo "Avvio Node 1 (Cowboy API/WS) sulla porta 8081..."
erl -sname node1@localhost -setcookie $COOKIE $PATHS -eval "bingo_app:start(8081)." -detached
#gnome-terminal -- bash -c "
#erl -sname node1@localhost -setcookie $COOKIE $PATHS -eval 'bingo_app:start(8081).';
#exec bash
#"

echo "Avvio Node 2 (Cowboy API/WS) sulla porta 8082..."
erl -sname node2@localhost -setcookie $COOKIE $PATHS -eval "bingo_app:start(8082)." -detached

# Diamo 2 secondi di respiro alla Erlang VM per far partire Cowboy e i listener TCP
sleep 2

# 2. Avvio del Main Server (Orchestratore)
# Il Main Server si connette ai nodi web, inizializza Mnesia distribuito e fa da monitor[cite: 53, 54].
# Usiamo -noshell & per mandarlo in background ma tenerlo legato alla sessione corrente.
echo "Avvio Main Node (Orchestratore e DB Mnesia)..."
erl -sname main_node@localhost -setcookie $COOKIE $PATHS -eval "main_server:start_link(['node1@localhost', 'node2@localhost'])." -noshell &

echo ""
echo "========================================================"
echo "🎯 CLUSTER AVVIATO CON SUCCESSO!"
echo "========================================================"
echo "- Node 1 è in ascolto su http://localhost:8081"
echo "- Node 2 è in ascolto su http://localhost:8082"
echo "- Main Node sta monitorando i nodi e gestendo Mnesia."
echo ""
echo "Per testare in locale senza Nginx:"
echo "Ricordati di puntare il tuo app.js a 'http://localhost:8081' (o 8082) e apri index.html nel browser."
echo "========================================================"