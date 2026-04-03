let currentUser = null;
let ws = null;
let currentGameId = undefined;
let pingInterval = null;
let clickCells = false;

// --- API HTTP ---

async function register() {
    const regex = /^(?=.*[A-Z])(?=.*\d)(?=.*[\W_]).{8,}$/;

    const user = document.getElementById('reg-username').value;
    const pass = document.getElementById('reg-password').value;
    const conf_pass = document.getElementById('confirm-password').value;

    if (pass !== conf_pass) {
        document.getElementById('register-msg').innerText = "Passwords do not match.";
        return;
    }

    if (!regex.test(pass)) {
        document.getElementById('register-msg').innerText =
            "Your password is not strong enough. It must be at least 8 characters, contain at least 1 uppercase letter, 1 number and 1 special character.";
        return;
    }

    const res = await fetch('/api/register', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: user, password: pass, confirm_password: conf_pass})
    });
    const data = await res.json();
    if (data.status === "ok") {
        document.getElementById('register-section').style.display = 'none';
        document.getElementById('auth-section').style.display = 'flex';
        document.getElementById('auth-msg').innerText = data.message;
    } else {
        document.getElementById('register-msg').innerText = data.message;
    }
}

function goRegister() {
    document.getElementById('auth-section').style.display = 'none';
    document.getElementById('register-section').style.display = 'flex';
    document.getElementById('register-msg').innerText = "Please enter a username and a password, then confirm the password.\nThe password must be at least 8 characters long and must contain at least one upper-case character, 1 number and 1 special character.";
}

function goLogin() {
    document.getElementById('register-section').style.display = 'none';
    document.getElementById('auth-section').style.display = 'flex';
    document.getElementById('auth-msg').innerText = "";
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
        currentGameID = data.game_id;
        
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

        ws.send(JSON.stringify({
            action: "authenticate"
        }));

        pingInterval = setInterval(() => {
            if (ws.readyState === WebSocket.OPEN) {
                // Puoi inviare una stringa semplice o un JSON
                ws.send(JSON.stringify({ action: 'ping' })); 
            }
        }, 30000);
    };

    ws.onmessage = (event) => {
        const msg = JSON.parse(event.data);
        handleServerMessage(msg);
    };

    ws.onclose = () => {
        logMessage("Connection lost. Trying to reconnect...");
        clearInterval(pingInterval);
        // Qui andrebbe implementata una logica di retry (utile in caso di crash di un nodo)
        setTimeout(connectWebSocket, 3000); 
    };
}

function handleServerMessage(msg) {
    console.log("Received message:", msg);
    switch (msg.event) {
        case "game_created":
            document.getElementById('players-count-game').innerText = "1";
            document.getElementById('btn-start').style.display = 'inline-block';
            enterGame(msg.game_id);
            logMessage(`Game created.`);
            logMessage(`Waiting for the game to start.`);
            break;
        case "joined":
            document.getElementById('btn-start').style.display = 'none';
            document.getElementById('players-count-game').innerText = msg.player_count;
            enterGame(msg.game_id);
            logMessage(`Joined game successfully.`);
            logMessage(`Waiting for the game to start.`);
            break;
        case "card_bought":
            renderCard(msg.grid);
            document.getElementById('balance-display').innerText = msg.balance;
            break;
        case "game_started":
            logMessage(`Game started! Total pot: ${msg.pot}`);
            document.getElementById('controls').style.display = 'flex';
            document.getElementById('btn-buy').style.display = 'none';
            document.getElementById('btn-start').style.display = 'none';
            clickCells = true;
            break;
        case "number_drawn":
            document.getElementById('last-number').innerText = msg.number;
            logMessage(`Number extracted: ${msg.number}`);
            break;
        case "win_accepted":
            document.getElementById('balance-display').innerText = msg.balance;
            break;
        case "winner_announced":
            logMessage(`${msg.user} won ${msg.combination}! Prize: ${msg.prize}`);
            break;
        case "game_over":
            logMessage("TOMBOLA! The game is over.");
            break;
        case "show_open_games":
        case "leave_game":
            exitGame(msg.open_games)
            break;
        case "user_reconnected":
            const playersCountJoin = document.getElementById('players-count-game');
            playersCountJoin.innerText = parseInt(playersCountJoin.innerText) + 1;
            logMessage(`${msg.user} reconnected to the game.`);
            break;
        case "user_joined":
            playersCountJoin = document.getElementById('players-count-game');
            playersCountJoin.innerText = parseInt(playersCountJoin.innerText) + 1;
            logMessage(`${msg.user} joined the game.`);
            break;
        case "user_disconnected":
            const playersCountLeave = document.getElementById('players-count-game');
            playersCountLeave.innerText = parseInt(playersCountLeave.innerText) - 1;
            logMessage(`${msg.user} disconnected from the game.`);
            break;
        case "user_left":
            playersCountLeave = document.getElementById('players-count-game');
            playersCountLeave.innerText = parseInt(playersCountLeave.innerText) - 1;
            logMessage(`${msg.user} left the game.`);
            break;
        case "game_cancelled":
            exitGame(msg.open_games)
            break;
        case "restore_game":
            // TODO ripristinare cartelle del coglione
            enterGame(msg.game_id);
            document.getElementById('controls').style.display = 'flex';
            document.getElementById('btn-buy').style.display = 'none';
            document.getElementById('btn-start').style.display = 'none';
            logMessage(`Reconnected to the game.`);
            break;
        case "error":
            showError(msg.reason);
            break;
    }
}

// --- AZIONI GIOCO ---

function createGame() {
    ws.send(JSON.stringify({ action: "create_game" }));
}

function joinGame(gameId) {
    ws.send(JSON.stringify({ action: "join_game", game_id: gameId }));
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

function searchOpenGames() {
    ws.send(JSON.stringify({ action: "search_open_games" }));
}

function leaveGame() {
    ws.send(JSON.stringify({ action: "leave_game" }));
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
            if(!clickCells) return;
            if(cell.style.backgroundColor == 'lightgreen')
                cell.style.backgroundColor = '';
            else
                cell.style.backgroundColor = 'lightgreen';
        };
        cardDiv.appendChild(cell);
    });
    
    container.appendChild(cardDiv);
}

function logMessage(text) {
    const log = document.getElementById('game-log');
    p = document.createElement('p');
    p.innerText = text;
    log.prepend(p);
}

function showOpenGames(open_games) {
    const lobbyDiv = document.getElementById('lobby-games-list');
    lobbyDiv.replaceChildren();

    if(open_games == null) return;
    
    if (open_games.length === 0) {
        p = document.createElement('p');
        p.innerText = "There are no open matches! Create a new one";
        lobbyDiv.appendChild(p);
    } else {
        // For each game, create a row with the creator's name and a Join button
        open_games.forEach(game => {
            const gameRow = document.createElement('div');
            gameRow.style.marginBottom = "10px";
            
            const infoText = document.createElement('span');
            const creator = String.fromCodePoint(...game.creator);
            const playerCount = game.player_count;
            infoText.innerText = `Game created by ${creator}, Players: ${playerCount}`;
            
            const btn = document.createElement('button');
            btn.innerText = 'Join';
            btn.onclick = () => joinGame(game.game_id);
            
            gameRow.appendChild(infoText);
            gameRow.appendChild(btn);
            lobbyDiv.appendChild(gameRow);
        });
    }
}

function enterGame(game_id) {
    document.getElementById('lobby').style.display = 'none';
    document.getElementById('play-area').style.display = 'block';
    document.getElementById('lobby-games-list').replaceChildren();
    document.getElementById('cards-container').replaceChildren();
    document.getElementById('last-number').innerText = '-';
    document.getElementById('controls').style.display = 'none';
    document.getElementById('btn-buy').style.display = 'inline-block';
    currentGameId = game_id;
}

function exitGame(open_games) {
    document.getElementById('lobby').style.display = 'flex';
    document.getElementById('play-area').style.display = 'none';
    clickCells = false;
    currentGameId = undefined;
    showOpenGames(open_games);
}

function showError(message, duration = 3000) {
    const errorDiv = document.getElementById('error-message');
    errorDiv.innerText = message;
    errorDiv.style.display = 'block';
    errorDiv.style.opacity = 1; // pieno

    // Dopo un breve delay, inizia il fade-out
    setTimeout(() => {
        errorDiv.style.opacity = 0;
    }, 100); // ritardo minimo per far partire la transizione

    // Nasconde completamente dopo la durata
    setTimeout(() => {
        errorDiv.style.display = 'none';
    }, duration);
}