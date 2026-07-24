# 🎯 Distributed Real-Time Bingo Platform

[![Erlang/OTP](https://img.shields.io/badge/Erlang%2FOTP-24%2B-red.svg)](https://www.erlang.org/)
[![Mnesia](https://img.shields.io/badge/Database-Mnesia-blue.svg)](https://erlang.org/doc/man/mnesia.html)
[![Cowboy](https://img.shields.io/badge/Web%20Server-Cowboy-orange.svg)](https://github.com/ninenines/cowboy)
[![NGINX](https://img.shields.io/badge/Load%20Balancer-NGINX-green.svg)](https://nginx.org/)
[![License](https://img.shields.io/badge/License-MIT-brightgreen.svg)](#)

A high-availability, fault-tolerant distributed multiplayer **Bingo / Tombola game engine** built with **Erlang/OTP**, **Mnesia DB**, **Cowboy**, and **NGINX**.

Developed for the *Distributed Systems and Middleware Technologies (DSMT)* course at the University of Pisa.

---

## ✨ Key Features

- **Actor Model Concurrency**: Isolated `gen_server` processes for each game room with real-time WebSocket communication.
- **Distributed Database**: Multi-node Mnesia cluster combining persistent disk storage (`disc_copies`) for user accounts and in-memory replication (`ram_copies`) for real-time game states.
- **Fault Tolerance & Auto-Refunds**: Automated node failure detection (`nodedown`). If a node crashes, an atomic transaction automatically refunds player card balances.
- **Load Balancing**: NGINX reverse proxy distributing HTTP API and WebSocket connections using `least_conn`.
- **Secure Authentication**: Passwords hashed with **PBKDF2-HMAC-SHA256** (10,000 iterations + 16-byte salt) and session tokens managed via `HttpOnly` cookies.
- **Game Engine**: Real-time room creation, card purchasing, ready-checks, automated number drawing, and server-side verification for Ambo, Terno, Quaterna, Cinquina, and Bingo.

---

## 🛠️ Tech Stack

| Layer | Component | Technology |
| :--- | :--- | :--- |
| **Backend Engine** | Concurrency & Logic | Erlang/OTP (`gen_server`, `rpc`, `net_kernel`) |
| **Database** | Distributed DBMS | Mnesia DB (ACID Transactions) |
| **HTTP & WS** | Web Framework | Cowboy (`cowboy_http`, `cowboy_websocket`) |
| **Proxy** | Load Balancer | NGINX (`least_conn`) |
| **Serialization** | JSON | `jsx` |
| **Frontend** | User Interface | Vanilla JavaScript (ES6+), HTML5, CSS3 |

---

## 🏛️ System Architecture Overview

- **Main Orchestrator (`main_node`)**: Monitors cluster nodes, manages Mnesia schema synchronization, and runs background session garbage collection.
- **Worker Nodes (`node1`, `node2`)**: Run Cowboy servers to process HTTP registration/login requests and maintain active WebSocket client connections.
- **NGINX Proxy**: Entry point balancing traffic across worker nodes and handling WebSocket protocol upgrades.

---

## 📁 Project Structure

```text
DSMT-BingoGame/
├── client/                     # Frontend Application (HTML/CSS/JS)
│   ├── index.html              # UI Web Page
│   ├── style.css               # Modern UI Styles
│   └── app.js                  # Client WebSocket & UI Logic
├── server/                     # Erlang Backend Core
│   ├── include/
│   │   └── bingo_records.hrl   # Mnesia DB Record Schema
│   ├── src/
│   │   ├── bingo_app.erl       # Application Bootstrap & Cowboy Router
│   │   ├── main_server.erl     # Orchestrator & Fault Manager
│   │   ├── game_server.erl     # Individual Game FSM
│   │   ├── db_manager.erl      # Mnesia Distributed Setup
│   │   ├── http_handler.erl    # REST API Handler
│   │   └── ws_handler.erl      # WebSocket Handler
│   ├── Makefile                # Build Script
│   └── start_cluster.sh        # Local Startup Script
├── nginx.conf                  # Load Balancer Configuration
└── commands.txt                # Distributed Command Reference
```

---

## 🚀 Quickstart

### Prerequisites
- Erlang/OTP 24+
- GNU Make

### Run Locally (3-Node Cluster)

1. **Compile Backend**:
   ```bash
   cd server
   make clean-all
   make
   ```

2. **Start Cluster**:
   ```bash
   chmod +x start_cluster.sh
   ./start_cluster.sh
   ```

3. **Launch Frontend**:
   Open `client/index.html` in your web browser.

---

## 🔌 API & WebSocket Reference

### HTTP REST API
- `POST /api/register` – Create user account.
- `POST /api/login` – Authenticate user and receive HTTP-Only session token.

### WebSocket Events (`/ws`)
- **Client Actions**: `create_game`, `join_game`, `buy_card`, `set_ready`, `claim_win`, `leave_game`.
- **Server Events**: `game_created`, `card_bought`, `number_drawn`, `win_announced`, `game_cancelled`.

---

## 👨‍💻 Authors

- **Dario Bandecchi** – [@Dariobande](https://github.com/Dariobande)
- **Matteo Giugni**

*Course*: Distributed Systems and Middleware Technologies (DSMT) – University of Pisa

---

## 📜 License

Distributed under the **MIT License**.
