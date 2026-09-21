# DSMT - Distributed Real-Time Bingo Platform

[![Erlang/OTP](https://img.shields.io/badge/Language-Erlang%2FOTP%2024%2B-red.svg)](https://www.erlang.org/)
[![Mnesia](https://img.shields.io/badge/Database-Mnesia-blue.svg)](https://erlang.org/doc/man/mnesia.html)
[![Cowboy](https://img.shields.io/badge/Web%20Server-Cowboy-orange.svg)](https://github.com/ninenines/cowboy)
[![NGINX](https://img.shields.io/badge/Load%20Balancer-NGINX-green.svg)](https://nginx.org/)

This repository contains the design, Erlang/OTP implementation, and functional verification of a high-availability, fault-tolerant **Distributed Real-Time Multiplayer Bingo Platform** built using Mnesia DB, Cowboy Web Server, and NGINX load balancing.

The project was developed for the **Distributed Systems and Middleware Technologies** course (Master of Science in Computer Engineering, **Università di Pisa**).

---

## Project Overview

The system implements a concurrent, multi-node Bingo (Tombola) engine using the Erlang Actor Model. The game logic relies on isolated state machines (`gen_server`) handling room creation, card distribution, synchronized number drawing, and server-side evaluation of winning combinations:

$$C_{\text{win}} \in \{\text{Ambo}, \text{Terno}, \text{Quaterna}, \text{Cinquina}, \text{Bingo}\}$$

Key system properties include:
- **High Concurrency & Isolation:** Each active game room runs as an autonomous `gen_server` process with real-time WebSocket state broadcasting.
- **Distributed Data Replication:** Hybrid storage architecture utilizing Mnesia's `disc_copies` for persistent user accounts and `ram_copies` for volatile game and session states across worker nodes.
- **Fault Tolerance & Automated Refunds:** Active cluster monitoring via `net_kernel`. In the event of a worker node crash (`nodedown`), an atomic transaction refunds player card investments to maintain data consistency.
- **Security & Authentication:** Password protection using **PBKDF2-HMAC-SHA256** key derivation (10,000 iterations with 16-byte cryptographically secure salt) and HTTP-Only session tokens.
- **Scalable Load Balancing:** Reverse proxy configuration using NGINX with `least_conn` routing for REST APIs and WebSocket upgrades.

---

## Specifications & Data Schema

System data records and parameters are defined in [`bingo_records.hrl`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/server/include/bingo_records.hrl) and managed transactionally via Mnesia:

| Entity | Primary Key | Storage Engine | Record Fields | Description |
| :--- | :---: | :---: | :--- | :--- |
| **User (`user`)** | `username` | `disc_copies` | `username`, `password_hash`, `salt`, `balance` | Persistent account profile, credentials, and virtual balance |
| **Session (`session`)** | `token` | `ram_copies` | `token`, `username`, `game_id`, `last_active` | Active client session mapping and heartbeat timestamp |
| **Game (`game`)** | `game_id` | `ram_copies` | `game_id`, `creator`, `status`, `drawn_numbers`, `pot`, `players`, `won_combinations` | Global game state, pot total, and claimed combination flags |
| **Card (`card`)** | `card_id` | `ram_copies` | `card_id`, `user_id`, `game_id`, `grid` | Player card instance containing 15 unique numbers |

### Winning Conditions & Combination Logic

Winning claims are evaluated server-side upon receiving a `claim_win` event. Valid winning combinations on a 15-number grid (3 rows of 5 numbers) are strictly ordered:

| Combination | Required Matched Numbers | Scope | Description |
| :--- | :---: | :---: | :--- |
| **Ambo** | 2 numbers | Single row | First player to match 2 drawn numbers on any single row |
| **Terno** | 3 numbers | Single row | First player to match 3 drawn numbers on any single row |
| **Quaterna** | 4 numbers | Single row | First player to match 4 drawn numbers on any single row |
| **Cinquina** | 5 numbers | Single row | First player to match all 5 drawn numbers on any single row |
| **Bingo** | 15 numbers | Full card | First player to match all 15 drawn numbers across all 3 rows |

---

## Architecture & System Design Details

The top-level distributed architecture is modular and partitioned into five core sub-blocks:

1. **Orchestrator Node ([`main_server.erl`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/server/src/main_server.erl)):**
   - Monitors cluster node states using `net_kernel:monitor_nodes/2`.
   - Coordinates multi-node Mnesia schema initialization and node join procedures (`db_manager:init_db/1`).
   - Implements automated recovery routines on `nodedown` events to refund affected players.
   - Executes periodic background cleanup routines for expired sessions.

2. **Game State Machine ([`game_server.erl`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/server/src/game_server.erl)):**
   - Implements finite state transitions (`waiting` -> `playing` -> `finished`).
   - Manages card purchasing transactions, player ready synchronization, and automated number generation ($1 \dots 90$).
   - Validates client win claims against drawn number sequences and updates game pot distribution.

3. **Database & Storage Manager ([`db_manager.erl`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/server/src/db_manager.erl), [`bingo_records.hrl`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/server/include/bingo_records.hrl)):**
   - Manages Mnesia distributed tables and schema setup across nodes.
   - Executes atomic transactions (`mnesia:transaction/1`) ensuring thread-safe balance updates, session creation, and card allocation.

4. **HTTP & WebSocket Gateway ([`bingo_app.erl`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/server/src/bingo_app.erl), [`http_handler.erl`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/server/src/http_handler.erl), [`ws_handler.erl`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/server/src/ws_handler.erl)):**
   - Configures Cowboy HTTP routing for REST authentication endpoints (`/api/register`, `/api/login`).
   - Handles low-latency WebSocket upgrades (`/ws`) for bidirectional event streaming (`create_game`, `buy_card`, `set_ready`, `claim_win`).

5. **Load Balancer & Client Interface ([`nginx.conf`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/nginx.conf), [`client/app.js`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/client/app.js)):**
   - NGINX reverse proxy distributing web requests using the `least_conn` strategy.
   - Lightweight Single-Page Application (SPA) built with vanilla HTML5/CSS3/JS rendering real-time game cards, drawn numbers, and active room states.

---

## Repository Structure

```
.
├── client/                     # Frontend Application Files
│   ├── index.html              # Main Web Application Page
│   ├── style.css               # User Interface Styling
│   └── app.js                  # Client WebSocket Client & UI Controller
├── server/                     # Erlang/OTP Backend Source Code
│   ├── include/
│   │   └── bingo_records.hrl   # Mnesia DB Record Schemas
│   ├── src/
│   │   ├── bingo_app.erl       # Cowboy Server Routing & Application Entrypoint
│   │   ├── main_server.erl     # Cluster Orchestrator & Node Monitoring
│   │   ├── game_server.erl     # Room Finite State Machine (gen_server)
│   │   ├── db_manager.erl      # Distributed Mnesia Setup & Data Operations
│   │   ├── http_handler.erl    # REST API Registration/Login Handlers
│   │   └── ws_handler.erl      # Real-Time WebSocket Request/Event Handler
│   ├── Makefile                # Compilation & Environment Clean Script
│   └── start_cluster.sh        # Local Multi-Node Cluster Launcher
├── nginx.conf                  # Load Balancer & Reverse Proxy Configuration
└── commands.txt                # Multi-Host Command Execution Reference
```

> **Note on omitted folders and dependencies (`ebin/`, `Mnesia.*/`, `deps/`):**  
> Compiled Erlang beam files (`ebin/`) and local Mnesia database transaction logs (`Mnesia.*/`) are ignored by version control to maintain a clean repository. The third-party dependencies (`cowboy`, `jsx`) reside in `server/deps/` and can be fetched and built as described in the setup instructions below.

---

## Cluster Setup & Execution Guide

### Prerequisites & Dependencies
- **Erlang/OTP 24+**
- **GNU Make**
- **Rebar3** (for compiling `jsx`)
- **NGINX** (for multi-node production deployment and load balancing)

#### External Dependencies Setup (`server/deps/`)
The backend relies on two external libraries: **Cowboy** (HTTP/WebSocket server) and **jsx** (JSON encoding/decoding). If `server/deps/` is unpopulated or needs to be built on a fresh clone, run:

```bash
cd server/deps

# 1. Fetch and compile Cowboy (automatically builds internal deps cowlib and ranch)
git clone https://github.com/ninenines/cowboy.git cowboy
cd cowboy && make && cd ..

# 2. Fetch and compile jsx
git clone https://github.com/talentdeficit/jsx.git jsx
cd jsx && rebar3 compile && cd ../..
```

### Local 3-Node Cluster Execution

1. **Compile Backend**:
   ```bash
   cd server
   make clean-all
   make
   ```

2. **Launch Cluster Nodes**:
   ```bash
   chmod +x start_cluster.sh
   ./start_cluster.sh
   ```
   This script initializes two Cowboy worker nodes (`node1@localhost`, `node2@localhost`) and the orchestrator node (`main_node@localhost`).

3. **Access Frontend**:
   Open [`client/index.html`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/client/index.html) directly in a web browser, or serve it via NGINX.

### Distributed Multi-Host Deployment

> **Note on IP addresses:**  
> The IP addresses listed below and in [`commands.txt`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/commands.txt) (`10.2.1.9`, `10.2.1.10`, `10.2.1.35`, `10.2.1.36`) are **purely indicative example addresses** configured during local testing on a private lab subnet. They are not active or reachable hosts. For real deployment, substitute them with the actual private/public IPs or DNS hostnames of your machines.

To run across separate physical host machines (as configured in [`commands.txt`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/commands.txt)):

1. **Start Worker Node 1 (`10.2.1.9`):**
   ```bash
   erl -name node1@10.2.1.9 -setcookie bingo_secret_cookie \
       -pa ebin/ -pa deps/jsx/ebin -pa deps/cowboy/ebin -pa deps/cowboy/deps/cowlib/ebin -pa deps/cowboy/deps/ranch/ebin \
       -eval 'bingo_app:start(8080, "10.2.1.35").'
   ```

2. **Start Worker Node 2 (`10.2.1.10`):**
   ```bash
   erl -name node2@10.2.1.10 -setcookie bingo_secret_cookie \
       -pa ebin/ -pa deps/jsx/ebin -pa deps/cowboy/ebin -pa deps/cowboy/deps/cowlib/ebin -pa deps/cowboy/deps/ranch/ebin \
       -eval 'bingo_app:start(8080, "10.2.1.35").'
   ```

3. **Start Main Orchestrator Node (`10.2.1.35`):**
   ```bash
   erl -name main_node@10.2.1.35 -setcookie bingo_secret_cookie \
       -pa ebin/ -pa deps/jsx/ebin -pa deps/cowboy/ebin -pa deps/cowboy/deps/cowlib/ebin -pa deps/cowboy/deps/ranch/ebin \
       -eval "main_server:start_link(['node1@10.2.1.9', 'node2@10.2.1.10'])."
   ```

4. **Run NGINX Reverse Proxy (`10.2.1.36`):**
   Apply [`nginx.conf`](file:///Users/dariobandecchi/Documents/GitHub/DSMT-BingoGame/nginx.conf) (updating upstream node addresses to match your network) and start NGINX:
   ```bash
   nginx -c /path/to/nginx.conf
   ```

---

## API & Protocol Reference

### HTTP REST API

| Endpoint | Method | Payload | Description |
| :--- | :---: | :--- | :--- |
| `/api/register` | `POST` | `{"username": "...", "password": "..."}` | Registers a new user account with default balance |
| `/api/login` | `POST` | `{"username": "...", "password": "..."}` | Authenticates user and returns an `HttpOnly` session cookie |

### WebSocket Protocol (`/ws`)

#### Client Requests
- `create_game`: Requests creation of a new game room instance.
- `join_game`: Connects player to a waiting game room.
- `buy_card`: Purchases one or more Bingo cards (deducting balance).
- `set_ready`: Signals readiness to start number extraction.
- `claim_win`: Submits a claim for Ambo, Terno, Quaterna, Cinquina, or Bingo.
- `leave_game`: Disconnects player and cleans up active room reference.

#### Server Events
- `game_created`: Broadcasts new game ID and room status.
- `card_bought`: Returns generated 15-number card grid to player.
- `number_drawn`: Streams newly drawn number (1–90) to all room participants.
- `win_announced`: Broadcasts validated winner details and payout updates.
- `game_cancelled`: Sent upon player disconnection or node failure refund processing.
