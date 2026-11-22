// Chelate ↔ noVNC bridge.
//
// The WebSocket to PVE's vncwebsocket is opened natively (URLSessionWebSocketTask) so that the
// auth cookie / API token header and certificate pinning are handled in Swift. This page hands
// noVNC a WebSocket-like "raw channel" (noVNC's RFB constructor accepts any object with
// send/close/binaryType/onopen/onmessage/onclose/onerror/protocol/readyState) whose traffic is
// relayed through WKScriptMessageHandler (JS → native) and callAsyncJavaScript (native → JS).

import RFB from './noVNC/core/rfb.js';
import KeyTable from './noVNC/core/input/keysym.js';
import keysyms from './noVNC/core/input/keysymdef.js';

const native = window.webkit.messageHandlers.chelate;
const screen = document.getElementById('screen');
const keyboardInput = document.getElementById('keyboard-input');

function post(message) {
    native.postMessage(message);
}

function bytesToBase64(bytes) {
    let binary = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(binary);
}

function base64ToBuffer(b64) {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
}

class NativeChannel {
    constructor() {
        // All required properties must exist as own keys for noVNC's attach() check.
        this.binaryType = 'arraybuffer';
        this.protocol = 'binary';
        this.readyState = 'open';
        this.onopen = null;
        this.onmessage = null;
        this.onclose = null;
        this.onerror = null;
    }

    send(data) {
        if (this.readyState !== 'open') {
            return;
        }
        let bytes;
        if (data instanceof ArrayBuffer) {
            bytes = new Uint8Array(data);
        } else if (ArrayBuffer.isView(data)) {
            bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        } else {
            bytes = new TextEncoder().encode(String(data));
        }
        post({ type: 'send', data: bytesToBase64(bytes) });
    }

    close() {
        if (this.readyState === 'closed') {
            return;
        }
        this.readyState = 'closed';
        post({ type: 'close' });
    }

    deliver(b64) {
        if (this.readyState === 'open' && this.onmessage) {
            this.onmessage({ data: base64ToBuffer(b64) });
        }
    }

    remoteClosed(code, reason) {
        if (this.readyState === 'closed') {
            return;
        }
        this.readyState = 'closed';
        if (this.onclose) {
            this.onclose({ code: code, reason: reason || '', wasClean: code === 1000 });
        }
    }
}

let rfb = null;
let channel = null;
let password = '';

function press(keysym, code) {
    if (rfb) {
        rfb.sendKey(keysym, code);
    }
}

function typeText(text) {
    for (const ch of text) {
        if (ch === '\n') {
            press(KeyTable.XK_Return, 'Enter');
            continue;
        }
        const keysym = keysyms.lookup(ch.codePointAt(0));
        press(keysym, null);
    }
}

// Soft keyboard: a hidden textarea; beforeinput gives us the intent without keeping text.
keyboardInput.addEventListener('beforeinput', (event) => {
    switch (event.inputType) {
    case 'insertCompositionText':
        return; // IME in progress, handled on compositionend
    case 'insertText':
    case 'insertReplacementText':
        typeText(event.data || '');
        break;
    case 'insertLineBreak':
    case 'insertParagraph':
        press(KeyTable.XK_Return, 'Enter');
        break;
    case 'deleteContentBackward':
    case 'deleteWordBackward':
        press(KeyTable.XK_BackSpace, 'Backspace');
        break;
    case 'deleteContentForward':
        press(KeyTable.XK_Delete, 'Delete');
        break;
    default:
        break;
    }
    event.preventDefault();
});

keyboardInput.addEventListener('compositionend', (event) => {
    typeText(event.data || '');
    keyboardInput.value = '';
});

const specialKeys = {
    Escape: [KeyTable.XK_Escape, 'Escape'],
    Tab: [KeyTable.XK_Tab, 'Tab'],
    ArrowUp: [KeyTable.XK_Up, 'ArrowUp'],
    ArrowDown: [KeyTable.XK_Down, 'ArrowDown'],
    ArrowLeft: [KeyTable.XK_Left, 'ArrowLeft'],
    ArrowRight: [KeyTable.XK_Right, 'ArrowRight'],
    Home: [KeyTable.XK_Home, 'Home'],
    End: [KeyTable.XK_End, 'End'],
    PageUp: [KeyTable.XK_Prior, 'PageUp'],
    PageDown: [KeyTable.XK_Next, 'PageDown'],
};

keyboardInput.addEventListener('keydown', (event) => {
    const special = specialKeys[event.key];
    if (special) {
        press(special[0], special[1]);
        event.preventDefault();
    }
});

keyboardInput.addEventListener('focus', () => post({ type: 'keyboard', visible: true }));
keyboardInput.addEventListener('blur', () => post({ type: 'keyboard', visible: false }));

function teardown() {
    if (rfb) {
        try {
            rfb.disconnect();
        } catch (e) {
            // ignore
        }
    }
    rfb = null;
    channel = null;
    screen.innerHTML = '';
}

window.chelate = {
    // Called by native once its WebSocket is open.
    connect(vncPassword) {
        teardown();
        password = vncPassword;
        channel = new NativeChannel();
        rfb = new RFB(screen, channel, {
            credentials: { password: password },
            shared: true,
        });
        rfb.scaleViewport = true;
        rfb.resizeSession = false;
        rfb.focusOnClick = false;
        rfb.background = '#000';
        rfb.addEventListener('connect', () => post({ type: 'status', state: 'connected' }));
        rfb.addEventListener('disconnect', (e) => post({ type: 'status', state: 'disconnected', clean: !!(e.detail && e.detail.clean) }));
        rfb.addEventListener('credentialsrequired', () => rfb.sendCredentials({ password: password }));
        rfb.addEventListener('securityfailure', (e) => post({
            type: 'status',
            state: 'securityfailure',
            reason: (e.detail && e.detail.reason) || '',
        }));
        rfb.addEventListener('desktopname', (e) => post({ type: 'desktopname', name: (e.detail && e.detail.name) || '' }));
    },
    receive(b64) {
        if (channel) {
            channel.deliver(b64);
        }
    },
    remoteClosed(code, reason) {
        if (channel) {
            channel.remoteClosed(code, reason);
        }
    },
    reset() {
        teardown();
    },
    sendCtrlAltDel() {
        if (rfb) {
            rfb.sendCtrlAltDel();
        }
    },
    sendKey(name) {
        const special = specialKeys[name];
        if (special) {
            press(special[0], special[1]);
        }
    },
    hideKeyboard() {
        keyboardInput.blur();
    },
};

// The soft keyboard can only be opened from a user gesture inside the page, so a small
// in-page button toggles it.
const keyboardButton = document.createElement('button');
keyboardButton.setAttribute('aria-label', '键盘');
keyboardButton.textContent = '⌨︎';
Object.assign(keyboardButton.style, {
    position: 'fixed',
    right: 'calc(12px + env(safe-area-inset-right))',
    bottom: 'calc(12px + env(safe-area-inset-bottom))',
    width: '44px',
    height: '44px',
    borderRadius: '22px',
    border: 'none',
    fontSize: '22px',
    color: '#fff',
    background: 'rgba(60, 60, 67, 0.75)',
    zIndex: '10',
});
keyboardButton.addEventListener('click', () => {
    if (document.activeElement === keyboardInput) {
        keyboardInput.blur();
    } else {
        keyboardInput.focus();
    }
});
document.body.appendChild(keyboardButton);

post({ type: 'ready' });
