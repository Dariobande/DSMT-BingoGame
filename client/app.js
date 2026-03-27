let currentUser = null;
let ws = null;
let currentGameId = null;

// --- API HTTP ---

async function register() {
    const user = document.getElementById('username').value;
    const pass = document.getElementById('password').value;
    const res = await fetch('/api/register', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: user, password: pass })
    });
    const data = await res.json();
    document.getElementById('auth-msg').innerText = data.message;
}

async function login() {
    const user = document.getElementById('username').value;
    const pass = document.getElementById('password').value;
    const res = await fetch('/api/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: user, password: pass })
    });
    const data = await res.json();
    
    if (data.status === "ok") {
        currentUser = user;
        document.getElementById('auth-section').style.display = 'none';
        document.getElementById('game-section').style.display = 'block';
        document.getElementById('user-display').innerText = currentUser;
        document.getElementById('balance-display').innerText = data.balance;
        
        // Inizializza la connessione WebSocket
        connectWebSocket();
    } else {
        document.getElementById('auth-msg').innerText = data.message;
    }
}

// --- LOGICA WEBSOCKET ---

function connectWebSocket() {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    ws = new WebSocket(`${protocol}//${window.location.host}/ws`);

    ws.onopen = () => {
        logMessage("Connected to server.");
    };

    ws.onmessage = (event) => {
        const msg = JSON.parse(event.data);
        handleServerMessage(msg);
    };

    ws.onclose = () => {
        logMessage("Connection lost. Trying to reconnect...");
        // Qui andrebbe implementata una logica di retry (utile in caso di crash di un nodo)
        setTimeout(connectWebSocket, 3000); 
    };
}

function handleServerMessage(msg) {
    switch (msg.event) {
        case "game_created":
            currentGameId = msg.game_id;
            document.getElementById('play-area').style.display = 'block';
            document.getElementById('btn-start').style.display = 'inline-block'; // Solo il creatore vede Start
            logMessage(`Game ${currentGameId} created.`);
            break;
        case "joined":
            document.getElementById('play-area').style.display = 'block';
            logMessage(`Joined game successfully.`);
            break;
        case "card_bought":
            renderCard(msg.grid);
            break;
        case "game_started":
            logMessage(`Game started! Total pot: ${msg.pot}`);
            break;
        case "number_drawn":
            document.getElementById('last-number').innerText = msg.number;
            logMessage(`Number extracted: ${msg.number}`);
            break;
        case "winner_announced":
            logMessage(`${msg.user} won ${msg.combination}! Prize: ${msg.prize}`);
            break;
        case "game_over":
            logMessage("TOMBOLA! The game is over.");
            break;
        case "error":
            alert(`Error: ${msg.reason}`);
            break;
    }
}

// --- AZIONI GIOCO ---

function createGame() {
    const gameId = document.getElementById('game-id-input').value || `game_${Date.now()}`;
    ws.send(JSON.stringify({ action: "create_game", username: currentUser, game_id: gameId }));
}

function joinGame() {
    const gameId = document.getElementById('game-id-input').value;
    ws.send(JSON.stringify({ action: "join_game", username: currentUser, game_id: gameId }));
}

function buyCard() {
    ws.send(JSON.stringify({ action: "buy_card", username: currentUser }));
}

function startGame() {
    ws.send(JSON.stringify({ action: "start_game" }));
}

function claimWin(combination) {
    // Nota: in una vera implementazione, si dovrebbe passare il CardId corretto
    ws.send(JSON.stringify({ action: "claim_win", combination: combination, card_id: "dummy_card_id" }));
}

function renderCard(grid) {
    const container = document.getElementById('cards-container');
    const cardDiv = document.createElement('div');
    cardDiv.className = 'bingo-card';
    
    // Genera una semplice griglia cliccabile
    grid.forEach(num => {
        const cell = document.createElement('div');
        cell.className = 'bingo-cell';
        cell.innerText = num;
        cell.onclick = () => {
            // L'utente clicca manualmente per segnare il numero [cite: 15]
            cell.style.backgroundColor = 'lightgreen';
        };
        cardDiv.appendChild(cell);
    });
    
    container.appendChild(cardDiv);
}

function logMessage(text) {
    const log = document.getElementById('game-log');
    log.innerHTML = text + "<br>" + log.innerHTML;
}