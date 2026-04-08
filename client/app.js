let currentUser = null;
let ws = null;
let currentGameId = undefined;
let pingInterval = null;
let clickCells = false;
let num_cards = 0;
let claim_win = null;

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
        currentGameId = data.game_id;
        
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
        if(currentGameId)
            logMessage("Connection lost during a game. Attempting to reconnect...");
        else
            showError("Connection lost. Please refresh the page to reconnect or wait for an automatic retry");

        clearInterval(pingInterval);
        // Qui andrebbe implementata una logica di retry (utile in caso di crash di un nodo)
        setTimeout(connectWebSocket, 3000); 
    };
}

function handleServerMessage(msg) {
    console.log("Received message:", msg);
    let playersCountJoin, playersCountLeave;
    switch (msg.event) {
        case "game_created":
            document.getElementById('players-count-game').innerText = "1";
            document.getElementById('btn-start').style.display = 'inline-block';
            document.getElementById('btn-ready').style.display = 'none';
            enterGame(msg.game_id);
            logMessage(`Game created.`);
            logMessage(`Waiting for the game to start.`);
            break;
        case "joined":
            document.getElementById('btn-start').style.display = 'none';
            document.getElementById('btn-ready').style.display = 'inline-block';
            document.getElementById('players-count-game').innerText = msg.player_count;
            enterGame(msg.game_id);
            logMessage(`Joined game successfully.`);
            logMessage(`Waiting for the game to start.`);
            break;
        case "card_bought":
            num_cards++;
            renderCard(msg.grid, msg.card_id);
            document.getElementById('balance-display').innerText = msg.balance;
            break;
        case "game_started":
            logMessage(`Game started! Total pot: ${msg.pot}`);
            document.getElementById('controls').style.display = 'flex';
            document.getElementById('btn-buy').style.display = 'none';
            document.getElementById('btn-start').style.display = 'none';
            document.getElementById('btn-ready').style.display = 'none';
            clickCells = true;
            break;
        case "number_drawn":
            document.getElementById('last-number').innerText = String(msg.number);
            logMessage(`Number extracted: ${msg.number}`);
            break;
        case "win_accepted":
            document.getElementById('balance-display').innerText = msg.balance;
            break;
        case "winner_announced":
            logMessage(`${msg.user} won ${msg.combination}! Prize: ${msg.prize}`);
            //disableCombinationButton(msg.combination);
            break;
        case "game_over":
            logMessage("BINGO! The game is over.");
            break;
        case "game_cancelled":
            showError("Game was cancelled: returned to lobby");
        case "show_open_games":
        case "leave_game":
            exitGame(msg.open_games, msg.balance);
            break;
        case "user_reconnected":
            playersCountJoin = document.getElementById('players-count-game');
            playersCountJoin.innerText = parseInt(playersCountJoin.innerText) + 1;
            logMessage(`${msg.user} reconnected to the game.`);
            break;
        case "user_joined":
            playersCountJoin = document.getElementById('players-count-game');
            playersCountJoin.innerText = parseInt(playersCountJoin.innerText) + 1;
            logMessage(`${msg.user} joined the game.`);
            break;
        case "user_disconnected":
            playersCountLeave = document.getElementById('players-count-game');
            playersCountLeave.innerText = parseInt(playersCountLeave.innerText) - 1;
            logMessage(`${msg.user} disconnected from the game.`);
            break;
        case "user_left":
            playersCountLeave = document.getElementById('players-count-game');
            playersCountLeave.innerText = parseInt(playersCountLeave.innerText) - 1;
            logMessage(`${msg.user} left the game.`);
            break;
        case "all_ready":
            logMessage(`All players currently in the game are ready.`);
            break;
        case "user_ready":
            logMessage(`${msg.user} is ready to play.`);
            break;
        case "restore_game":
            enterGame(msg.game_id);
            document.getElementById('players-count-game').innerText = parseInt(msg.player_count) - 1;
            document.getElementById('last-number').innerText = msg.drawn.length > 0 ? String(msg.drawn[0]) : '';
            num_cards = msg.cards.length();
            msg.cards.forEach(card => renderCard(card.grid, card.card_id, msg.drawn));
            // Disabilita i bottoni di vincita per le combinazioni già vinte
            /*msg.won.forEach(comb => {
                const btn = document.getElementById(`btn-${comb}`);
                if(btn) btn.disabled = true;
            });*/
            document.getElementById('controls').style.display = 'flex';
            document.getElementById('btn-buy').style.display = 'none';
            document.getElementById('btn-start').style.display = 'none';
            document.getElementById('btn-ready').style.display = 'none';
            clickCells = true;
            logMessage(`Reconnected to the game.`);
            msg.drawn.forEach(num => logMessage(`Number extracted: ${num}`));
            if (msg.won.length > 0)
                logMessage(`${msg.won[0]} is the latest winning combination claimed!`);
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
    claim_win = combination;
    if (combination !== 'tombola') {
        showError("Click on the row on which you want to claim the winning combination!");
    } else {
        showError("Click on the bingo card on which you want to claim BINGO!");
    }
}

function searchOpenGames() {
    ws.send(JSON.stringify({ action: "search_open_games" }));
}

function leaveGame() {
    ws.send(JSON.stringify({ action: "leave_game" }));
}

function readyToPlay() {
    ws.send(JSON.stringify({ action: "ready_to_play" }));
}

function renderCard(grid, cardId, drawnNumbers = []) {
    const container = document.getElementById('cards-container');
    const cardDiv = document.createElement('div');
    cardDiv.className = 'bingo-card';
    const drawnSet = new Set(drawnNumbers.map(Number));

    const rows = buildCardRows(grid);
    let currentRow = 0;
    rows.forEach(row => {
        for (let columnIndex = 0; columnIndex < 9; columnIndex++) {
            const cell = document.createElement('div');
            cell.className = 'bingo-cell';
            cell.id = 'card' + cardId + 'cell' + currentRow+columnIndex;

            const number = row[columnIndex];
            if (number == null) {
                cell.classList.add('bingo-cell-empty');
                cell.style.cursor = 'default';
                cell.style.pointerEvents = 'none';
                cardDiv.appendChild(cell);
                continue;
            }

            cell.innerText = number;
            if (drawnSet.has(Number(number))) {
                cell.style.backgroundColor = 'lightgreen';
            }
            cell.onclick = () => {
                if(claim_win !== null) {
                    numbers = checkPossibleCombination(claim_win, currentRow, cardId);
                    ws.send(JSON.stringify({ action: "claim_win", combination: claim_win, card_id: cardId, numbers: numbers}));
                    claim_win = null;
                    return;
                }
                if(!clickCells) return;
                if(cell.style.backgroundColor == 'lightgreen')
                    cell.style.backgroundColor = '';
                else
                    cell.style.backgroundColor = 'lightgreen';
            };
            cardDiv.appendChild(cell);
        }
        currentRow++;
    });
    
    container.appendChild(cardDiv);
}

function checkPossibleCombination(comb) {
    for (let card = 0; card < num_cards; card++) {
        let clicked_cells = 0;
        for (let row = 0; row < 3; row++) {
            if (comb !== 'tombola') {
                clicked_cells = 0;
            }
            let needed_cells = combToNumber(comb);
            for (let column = 0; column < 9; column++) {
                if(document.getElementById('card'+card+'cell'+row+column).style.backgroundColor == 'lightgreen') {
                    clicked_cells++;
                }
            }
            if (comb !== 'tombola' && clicked_cells >= needed_cells) {
                return true;
            }
        }
        if (comb === 'tombola' && clicked_cells >= '15') {
            return true;
        }
    }
    return false;
}

function combToNumber(comb) {
    switch (comb) {
        case 'ambo':
            return 2;
        case 'terno':
            return 3;
        case 'quaterna':
            return 4;
        case 'cinquina':
            return 5;
        case 'tombola':
            return 15;
    }
}

function buildCardRows(grid) {
    const rows = [Array(9).fill(null), Array(9).fill(null), Array(9).fill(null)];
    const numbersByRow = [grid.slice(0, 5), grid.slice(5, 10), grid.slice(10, 15)];

    numbersByRow.forEach((rowNumbers, rowIndex) => {
        rowNumbers.forEach(number => {
            const columnIndex = getDecadeColumn(number);
            rows[rowIndex][columnIndex] = number;
        });
    });

    return rows;
}

function getDecadeColumn(number) {
    const value = Number(number);

    if (value >= 80) return 8;
    if (value >= 70) return 7;
    if (value >= 60) return 6;
    if (value >= 50) return 5;
    if (value >= 40) return 4;
    if (value >= 30) return 3;
    if (value >= 20) return 2;
    if (value >= 10) return 1;
    return 0;
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
    document.getElementById('last-number').innerText = '';
    document.getElementById('controls').style.display = 'none';
    document.getElementById('btn-buy').style.display = 'inline-block';
    document.getElementById('game-log').replaceChildren();
    //enableGameButtons();
    currentGameId = game_id;
    num_cards = 0;
}

function exitGame(open_games, balance) {
    document.getElementById('lobby').style.display = 'flex';
    document.getElementById('play-area').style.display = 'none';
    if (balance !== "balance_unchanged" && Number.isInteger(balance))
        document.getElementById('balance-display').innerText = balance;
    clickCells = false;
    currentGameId = undefined;
    showOpenGames(open_games);
}

function enableGameButtons() {
    document.getElementById('btn-ambo').disabled = false;
    document.getElementById('btn-terno').disabled = false;
    document.getElementById('btn-quaterna').disabled = false;
    document.getElementById('btn-cinquina').disabled = false;
    document.getElementById('btn-tombola').disabled = false;
}

function disableCombinationButton(combination) {
    if (!combination) return;
    const btn = document.getElementById(`btn-${combination}`);
    if (btn) btn.disabled = true;
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

document.addEventListener("DOMContentLoaded", () => {
    const combinations = ["ambo", "terno", "quaterna", "cinquina", "tombola"];

    combinations.forEach(comb => {
        document.getElementById(`btn-${comb}`).addEventListener("click", () => claimWin(comb));
    });

    document.getElementById("btn-start").addEventListener("click", startGame);

    document.getElementById("btn-buy").addEventListener("click", buyCard);

    document.getElementById("btn-ready").addEventListener("click", readyToPlay);

    document.getElementById("btn-create").addEventListener("click", createGame);

    document.getElementById("btn-refresh").addEventListener("click", searchOpenGames);

    document.getElementById("btn-leave").addEventListener("click", leaveGame);

    document.getElementById("btn-register").addEventListener("click", register);

    document.getElementById("btn-login").addEventListener("click", login);

    document.getElementById("btn-go-login").addEventListener("click", goLogin);

    document.getElementById("btn-go-register").addEventListener("click", goRegister);
});