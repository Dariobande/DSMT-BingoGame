#!/bin/bash

# start_cluster.sh
# Assicurati di rendere eseguibile il file con: chmod +x start_cluster.sh

COOKIE="bingo_secret_cookie"
EBIN_DIR="./ebin"

echo "Avvio del cluster Erlang per il Bingo Distribuito..."

# 1. Avvio dei nodi Cowboy (Backend / API Web) in modalità detached (background)
# Assumiamo che l'applicazione bingo_app venga avviata su questi nodi
echo "Avvio Node 1 (Cowboy)..."
erl -sname node1@localhost -setcookie $COOKIE -pa $EBIN_DIR -eval "application:ensure_all_started(bingo_app)." -detached

echo "Avvio Node 2 (Cowboy)..."
erl -sname node2@localhost -setcookie $COOKIE -pa $EBIN_DIR -eval "application:ensure_all_started(bingo_app)." -detached

# Piccola pausa per dare tempo ai nodi di inizializzarsi
sleep 2

# 2. Avvio del Main Server (Orchestratore)
# Questo nodo non fa girare Cowboy, ma inizializza Mnesia e monitora i nodi.
echo "Avvio Main Node..."
# Passiamo la lista dei nodi al main_server:start_link/1
erl -sname main_node@localhost -setcookie $COOKIE -pa $EBIN_DIR -eval "main_server:start_link(['node1@localhost', 'node2@localhost'])." -noshell &

echo "Tutti i nodi sono stati avviati con successo!"
echo "Node 1 e Node 2 sono in ascolto per le connessioni in background."
echo "Il Main Node è in esecuzione e ha inizializzato il database Mnesia distribuito."
echo "Assicurati di avviare Nginx per instradare il traffico correttamente."