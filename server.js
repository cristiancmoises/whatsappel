'use strict';

const {
  default: makeWASocket,
  useMultiFileAuthState,
  DisconnectReason,
  fetchLatestBaileysVersion,
  makeCacheableSignalKeyStore,
  isJidGroup,
  isJidUser,
  jidNormalizedUser,
  getContentType,
  downloadMediaMessage,
  proto,
} = require('@whiskeysockets/baileys');
const express = require('express');
const multer = require('multer');
const { WebSocketServer } = require('ws');
const http = require('http');
const fs = require('fs');
const path = require('path');
const pino = require('pino');
const QRCode = require('qrcode');

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const CONFIG = {
  port: parseInt(process.env.WAEL_PORT || '3000', 10),
  wsPort: parseInt(process.env.WAEL_WS_PORT || '3001', 10),
  authDir: process.env.WAEL_AUTH_DIR || path.join(__dirname, 'auth_info'),
  mediaDir: process.env.WAEL_MEDIA_DIR || path.join(__dirname, 'media'),
  logLevel: process.env.WAEL_LOG_LEVEL || 'warn',
  storeFile: process.env.WAEL_STORE_FILE || path.join(__dirname, 'store.json'),
  apiToken: process.env.WAEL_API_TOKEN || '',  // Set to enable bearer auth
  rateLimit: parseInt(process.env.WAEL_RATE_LIMIT || '0', 10),  // requests/minute, 0=disabled
};

// ---------------------------------------------------------------------------
// Logger
// ---------------------------------------------------------------------------

const logger = pino({ level: CONFIG.logLevel });
const baileysLogger = pino({ level: 'silent' });

// ---------------------------------------------------------------------------
// In-memory store
// ---------------------------------------------------------------------------

class Store {
  constructor(filePath) {
    this.filePath = filePath;
    this.chats = new Map();     // jid -> { jid, name, unreadCount, lastMessage, pinned, muted, archived, isGroup, timestamp }
    this.contacts = new Map();  // jid -> { jid, name, pushName, imgUrl }
    this.messages = new Map();  // jid -> [{ id, jid, fromMe, sender, senderName, text, timestamp, status, quotedId, quotedText, quotedSender, type, reactions }]
    this.rawMessages = new Map(); // msgId -> raw Baileys message object (for media download)
    this.reactions = new Map(); // msgId -> Map(sender -> { emoji, timestamp })
    this.starred = new Set();  // msgId -> starred
    this.presence = new Map();  // jid -> { lastKnown, lastSeen }
    this.statusUpdates = [];   // Recent status/story updates
    this.lidToPn = new Map();   // @lid jid -> @s.whatsapp.net jid  (WhatsApp LID addressing)
    this.pnToLid = new Map();   // @s.whatsapp.net jid -> @lid jid
    this._load();
  }

  _load() {
    try {
      if (fs.existsSync(this.filePath)) {
        const data = JSON.parse(fs.readFileSync(this.filePath, 'utf8'));
        if (data.chats) for (const c of data.chats) this.chats.set(c.jid, c);
        if (data.contacts) for (const c of data.contacts) this.contacts.set(c.jid, c);
        if (data.starred) for (const id of data.starred) this.starred.add(id);
        if (data.lidMap) for (const [lid, pn] of data.lidMap) this.recordJidMapping(lid, pn);
        // Restore recent message history so chats are usable immediately after a restart
        if (data.messages) for (const [jid, msgs] of Object.entries(data.messages)) this.messages.set(jid, msgs);
        logger.info('Store loaded from disk');
      }
    } catch (err) {
      logger.warn({ err }, 'Failed to load store, starting fresh');
    }
  }

  save() {
    try {
      // Persist the last 80 messages per chat so history survives a restart.
      const messages = {};
      for (const [jid, arr] of this.messages) {
        if (arr.length) messages[jid] = arr.slice(-80);
      }
      const data = {
        chats: [...this.chats.values()],
        contacts: [...this.contacts.values()],
        starred: [...this.starred],
        lidMap: [...this.lidToPn.entries()],
        messages,
      };
      // Atomic write: write to a temp file then rename, so a crash mid-write
      // can never leave a truncated/corrupt store.json.
      const tmp = this.filePath + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(data), 'utf8');
      fs.renameSync(tmp, this.filePath);
    } catch (err) {
      logger.warn({ err }, 'Failed to save store');
    }
  }

  // Record a bidirectional mapping between a WhatsApp LID (@lid) and the
  // phone-number JID (@s.whatsapp.net) it belongs to.
  recordJidMapping(lid, pn) {
    if (!lid || !pn || lid === pn) return;
    if (!lid.endsWith('@lid') || !pn.endsWith('@s.whatsapp.net')) return;
    this.lidToPn.set(lid, pn);
    this.pnToLid.set(pn, lid);
  }

  // Best phone-number JID known for any jid (handles @lid -> @s.whatsapp.net).
  phoneJid(jid) {
    if (!jid) return null;
    if (jid.endsWith('@s.whatsapp.net')) return jid;
    if (jid.endsWith('@lid')) return this.lidToPn.get(jid) || null;
    return null;
  }

  // Best human-readable name for a *user* jid (not a group). Never throws.
  // Order: saved address-book name -> their pushName -> name/pushName of the
  // mapped alternate jid -> '' (caller falls back to a phone number).
  contactName(jid) {
    if (!jid) return '';
    const pick = (c) => c && (c.name || c.notify || c.pushName || '');
    let n = pick(this.contacts.get(jid));
    if (n) return n;
    const alt = this.lidToPn.get(jid) || this.pnToLid.get(jid);
    if (alt) { n = pick(this.contacts.get(alt)); if (n) return n; }
    return '';
  }

  upsertChat(jid, update) {
    const existing = this.chats.get(jid) || {
      jid,
      name: '',
      unreadCount: 0,
      lastMessage: null,
      pinned: false,
      muted: false,
      archived: false,
      isGroup: isJidGroup(jid),
      timestamp: 0,
    };
    Object.assign(existing, update);
    this.chats.set(jid, existing);
    return existing;
  }

  upsertContact(jid, update) {
    const existing = this.contacts.get(jid) || { jid, name: '', pushName: '', imgUrl: null };
    Object.assign(existing, update);
    this.contacts.set(jid, existing);
    return existing;
  }

  addMessage(jid, msg) {
    if (!this.messages.has(jid)) this.messages.set(jid, []);
    const arr = this.messages.get(jid);
    // Deduplicate by message id
    const idx = arr.findIndex(m => m.id === msg.id);
    if (idx >= 0) {
      arr[idx] = msg;
    } else {
      arr.push(msg);
      // Keep last 500 messages per chat in memory
      if (arr.length > 500) arr.splice(0, arr.length - 500);
    }
  }

  sortChat(jid) {
    const arr = this.messages.get(jid);
    if (arr && arr.length > 1) arr.sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));
  }

  getMessages(jid, limit = 50, beforeId = null) {
    const arr = this.messages.get(jid) || [];
    if (beforeId) {
      const idx = arr.findIndex(m => m.id === beforeId);
      if (idx > 0) {
        const start = Math.max(0, idx - limit);
        return arr.slice(start, idx);
      }
      return [];
    }
    return arr.slice(-limit);
  }

  updateMessageStatus(jid, msgId, status) {
    const arr = this.messages.get(jid) || [];
    const msg = arr.find(m => m.id === msgId);
    if (msg) msg.status = status;
  }

  deleteMessage(jid, msgId) {
    const arr = this.messages.get(jid) || [];
    const msg = arr.find(m => m.id === msgId);
    if (msg) {
      msg.deleted = true;
      msg.text = '';
    }
  }

  addReaction(msgId, sender, emoji) {
    if (!this.reactions.has(msgId)) this.reactions.set(msgId, new Map());
    const rxns = this.reactions.get(msgId);
    if (emoji === '' || emoji === null) {
      rxns.delete(sender);
    } else {
      rxns.set(sender, { emoji, timestamp: Date.now() });
    }
  }

  getReactions(msgId) {
    const rxns = this.reactions.get(msgId);
    if (!rxns || rxns.size === 0) return [];
    // Aggregate: { emoji: string, count: number, senders: string[] }
    const agg = new Map();
    for (const [sender, { emoji }] of rxns) {
      if (!agg.has(emoji)) agg.set(emoji, { emoji, count: 0, senders: [] });
      const entry = agg.get(emoji);
      entry.count++;
      entry.senders.push(sender);
    }
    return [...agg.values()];
  }

  updatePresence(jid, type) {
    this.presence.set(jid, { lastKnown: type, lastSeen: Date.now() });
  }

  getPresence(jid) {
    return this.presence.get(jid) || { lastKnown: 'unavailable', lastSeen: 0 };
  }

  storeRawMessage(msgId, rawMsg) {
    if (!msgId) return;
    this.rawMessages.set(msgId, rawMsg);
    // Keep raw messages for forward/quote/media-download. Matches the per-chat
    // message cache so anything visible can be acted on.
    if (this.rawMessages.size > 1000) {
      const first = this.rawMessages.keys().next().value;
      this.rawMessages.delete(first);
    }
  }

  getRawMessage(msgId) {
    return this.rawMessages.get(msgId) || null;
  }
}

const store = new Store(CONFIG.storeFile);

// Debounced persistence: coalesce the burst of save() calls during initial sync
// (hundreds of chat/contact events) into at most one disk write per second.
let _saveTimer = null;
function scheduleSave() {
  if (_saveTimer) return;
  _saveTimer = setTimeout(() => { _saveTimer = null; store.save(); }, 1000);
}

// Coalesce chat-list broadcasts so a burst of incoming messages doesn't push the
// full chat list over the socket once per message.
let _chatsBcTimer = null;
function scheduleChatsBroadcast() {
  if (_chatsBcTimer) return;
  _chatsBcTimer = setTimeout(() => { _chatsBcTimer = null; broadcast('chats.update', { chats: serializeChats() }); }, 400);
}

// ---------------------------------------------------------------------------
// WebSocket broadcast
// ---------------------------------------------------------------------------

let wss;
const wsClients = new Set();

function broadcast(event, data) {
  const frame = JSON.stringify({ event, data, ts: Date.now() });
  for (const client of wsClients) {
    if (client.readyState === 1) { // WebSocket.OPEN
      client.send(frame);
    }
  }
}

// ---------------------------------------------------------------------------
// Baileys connection
// ---------------------------------------------------------------------------

let sock = null;
let connectionState = 'disconnected'; // disconnected | connecting | open | qr
let currentQR = null;
let reconnectAttempt = 0;
const MAX_RECONNECT_DELAY = 30000;

function extractMessageContent(msg) {
  if (!msg.message) return { text: '', type: 'unknown' };

  const contentType = getContentType(msg.message);
  if (!contentType) return { text: '', type: 'unknown' };

  const content = msg.message[contentType];

  switch (contentType) {
    case 'conversation':
      return { text: msg.message.conversation || '', type: 'text' };
    case 'extendedTextMessage':
      return { text: content?.text || '', type: 'text' };
    case 'imageMessage':
      return { text: content?.caption || '[Image]', type: 'image' };
    case 'videoMessage':
      // WhatsApp "GIFs" are short looping MP4s flagged gifPlayback.
      return content?.gifPlayback
        ? { text: content?.caption || '[GIF]', type: 'gif' }
        : { text: content?.caption || '[Video]', type: 'video' };
    case 'audioMessage':
      return { text: '[Audio]', type: 'audio' };
    case 'documentMessage':
      return { text: content?.fileName || '[Document]', type: 'document' };
    case 'stickerMessage':
      return { text: '[Sticker]', type: 'sticker' };
    case 'locationMessage':
      return { text: `[Location: ${content?.degreesLatitude}, ${content?.degreesLongitude}]`, type: 'location' };
    case 'contactMessage':
      return { text: `[Contact: ${content?.displayName || ''}]`, type: 'contact' };
    case 'reactionMessage':
      return { text: content?.text || '', type: 'reaction' };
    case 'protocolMessage': {
      const pType = content?.type;
      if (pType === proto.Message.ProtocolMessage.Type.REVOKE) {
        return { text: '', type: 'revoke' };
      }
      if (pType === proto.Message.ProtocolMessage.Type.MESSAGE_EDIT) {
        const edited = content?.editedMessage;
        if (edited) {
          const inner = extractMessageContent({ message: edited });
          return { text: inner.text, type: 'edit' };
        }
      }
      return { text: '', type: 'protocol' };
    }
    case 'pollCreationMessage':
    case 'pollCreationMessageV3':
      return { text: `[Poll: ${content?.name || ''}]`, type: 'poll' };
    default:
      return { text: `[${contentType}]`, type: contentType };
  }
}

function extractQuotedInfo(msg) {
  const ext = msg.message?.extendedTextMessage;
  if (!ext?.contextInfo?.quotedMessage) return null;
  const quoted = extractMessageContent({ message: ext.contextInfo.quotedMessage });
  return {
    id: ext.contextInfo.stanzaId || null,
    sender: ext.contextInfo.participant || null,
    text: quoted.text,
  };
}

function normalizeMessage(msg, jid) {
  const { text, type } = extractMessageContent(msg);
  const quoted = extractQuotedInfo(msg);
  const sender = msg.key.fromMe
    ? (sock?.user?.id ? jidNormalizedUser(sock.user.id) : 'me')
    : (msg.key.participant || msg.key.remoteJid);
  const senderName = msg.pushName || store.contacts.get(sender)?.name || sender?.split('@')[0] || '';

  // Extract media metadata
  const contentType = msg.message ? getContentType(msg.message) : null;
  const content = contentType ? msg.message[contentType] : null;
  const mediaInfo = {};
  if (content && ['imageMessage', 'videoMessage', 'audioMessage', 'documentMessage', 'stickerMessage'].includes(contentType)) {
    mediaInfo.mimetype = content.mimetype || '';
    mediaInfo.fileLength = content.fileLength?.low || content.fileLength || 0;
    mediaInfo.fileName = content.fileName || '';
    mediaInfo.seconds = content.seconds || 0; // audio/video duration
    mediaInfo.ptt = !!content.ptt; // push-to-talk (voice note)
    mediaInfo.gifPlayback = !!content.gifPlayback; // looping GIF-style video
    mediaInfo.hasMedia = true;
  }

  // Extract link preview
  const linkPreview = {};
  const extText = msg.message?.extendedTextMessage;
  if (extText?.matchedText) {
    linkPreview.url = extText.matchedText;
    linkPreview.title = extText.title || '';
    linkPreview.description = extText.description || '';
    linkPreview.canonicalUrl = extText.canonicalUrl || extText.matchedText;
  }

  return {
    id: msg.key.id,
    jid,
    fromMe: !!msg.key.fromMe,
    sender,
    senderName,
    text,
    type,
    timestamp: (msg.messageTimestamp?.low || msg.messageTimestamp || 0) * 1000 || Date.now(),
    status: msg.status || 0,
    quotedId: quoted?.id || null,
    quotedText: quoted?.text || null,
    quotedSender: quoted?.sender || null,
    deleted: false,
    reactions: store.getReactions(msg.key.id),
    starred: store.starred.has(msg.key.id),
    ...mediaInfo,
    linkPreview: linkPreview.url ? linkPreview : null,
  };
}

async function startSock() {
  connectionState = 'connecting';
  broadcast('connection.update', { state: 'connecting' });

  fs.mkdirSync(CONFIG.authDir, { recursive: true });
  const { state, saveCreds } = await useMultiFileAuthState(CONFIG.authDir);
  const { version } = await fetchLatestBaileysVersion();

  sock = makeWASocket({
    version,
    auth: {
      creds: state.creds,
      keys: makeCacheableSignalKeyStore(state.keys, baileysLogger),
    },
    logger: baileysLogger,
    generateHighQualityLinkPreview: false,
    // Pull real conversation history from WhatsApp so opening a chat shows past
    // messages (not just whatever arrived live since the bridge started).
    syncFullHistory: true,
    shouldSyncHistoryMessage: () => true,
    // Don't force-mark ourselves online, so the phone keeps delivering history
    // and notifications normally.
    markOnlineOnConnect: false,
  });

  // --- Connection events ---

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', async (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      currentQR = qr;
      connectionState = 'qr';
      // Generate base64 PNG
      try {
        const qrDataUrl = await QRCode.toDataURL(qr, { width: 256 });
        broadcast('connection.update', { state: 'qr', qr: qrDataUrl });
      } catch (e) {
        broadcast('connection.update', { state: 'qr', qr: null });
      }
      logger.info('QR code generated — scan with WhatsApp');
    }

    if (connection === 'open') {
      connectionState = 'open';
      currentQR = null;
      reconnectAttempt = 0;
      logger.info('Connected to WhatsApp');
      broadcast('connection.update', {
        state: 'open',
        user: sock?.user ? { id: jidNormalizedUser(sock.user.id), name: sock.user.name } : null,
      });
      store.save();
      // Let the initial history/app-state sync settle, then backfill group
      // names + LID mappings (also re-run periodically as chats trickle in).
      setTimeout(() => backfillGroupMetadata().catch(() => {}), 3000);
    }

    if (connection === 'close') {
      connectionState = 'disconnected';
      const statusCode = lastDisconnect?.error?.output?.statusCode;
      const loggedOut = statusCode === DisconnectReason.loggedOut;

      broadcast('connection.update', {
        state: 'disconnected',
        reason: statusCode,
        loggedOut,
      });

      if (loggedOut) {
        logger.info('Logged out — clearing session');
        try { fs.rmSync(CONFIG.authDir, { recursive: true, force: true }); } catch {}
      } else {
        // Reconnect with backoff
        reconnectAttempt++;
        const delay = Math.min(1000 * Math.pow(2, reconnectAttempt - 1), MAX_RECONNECT_DELAY);
        const jitter = Math.floor(Math.random() * 500);
        logger.info({ delay: delay + jitter, attempt: reconnectAttempt }, 'Reconnecting...');
        setTimeout(startSock, delay + jitter);
      }
    }
  });

  // --- Message events ---

  sock.ev.on('messages.upsert', async ({ messages: msgs, type }) => {
    for (const msg of msgs) {
      const jid = msg.key.remoteJid;
      if (!jid) continue;

      // Capture status/story updates
      if (jid === 'status@broadcast') {
        const { text, type } = extractMessageContent(msg);
        const sender = msg.key.participant || '';
        const senderName = msg.pushName || store.contacts.get(sender)?.name || sender.split('@')[0] || '';
        store.statusUpdates.unshift({
          id: msg.key.id,
          sender,
          senderName,
          text: text || `[${type}]`,
          type,
          timestamp: ((msg.messageTimestamp?.low || msg.messageTimestamp || 0) * 1000) || Date.now(),
          hasMedia: ['image', 'video'].includes(type),
        });
        // Keep last 50 status updates
        if (store.statusUpdates.length > 50) store.statusUpdates.length = 50;
        broadcast('status.update', { status: store.statusUpdates[0] });
        continue;
      }

      const { type: msgType } = extractMessageContent(msg);

      // Handle reactions separately
      if (msgType === 'reaction') {
        const reaction = msg.message?.reactionMessage;
        if (reaction) {
          const targetMsgId = reaction.key?.id;
          const sender = msg.key.participant || msg.key.remoteJid;
          store.addReaction(targetMsgId, sender, reaction.text);
          broadcast('messages.reaction', {
            jid,
            msgId: targetMsgId,
            emoji: reaction.text,
            fromMe: !!msg.key.fromMe,
            sender,
            reactions: store.getReactions(targetMsgId),
          });
        }
        continue;
      }

      // Handle revoke (delete)
      if (msgType === 'revoke') {
        const protocol = msg.message?.protocolMessage;
        const revokedId = protocol?.key?.id;
        if (revokedId) {
          store.deleteMessage(jid, revokedId);
          broadcast('messages.delete', { jid, msgId: revokedId });
        }
        continue;
      }

      // Handle edits
      if (msgType === 'edit') {
        const protocol = msg.message?.protocolMessage;
        const editedId = protocol?.key?.id;
        if (editedId) {
          const normalized = normalizeMessage(msg, jid);
          normalized.id = editedId;
          normalized.edited = true;
          store.addMessage(jid, normalized);
          broadcast('messages.edit', { jid, message: normalized });
        }
        continue;
      }

      // Skip protocol messages we don't care about
      if (msgType === 'protocol') continue;

      const normalized = normalizeMessage(msg, jid);
      store.addMessage(jid, normalized);
      // Learn LID<->phone mappings carried on the message key.
      learnJidMapping(msg);
      // Accumulate the sender's pushName so names fill in over time. Never from
      // our own outgoing messages (that previously polluted chat names with our
      // own number).
      if (!msg.key.fromMe && msg.pushName && normalized.sender) {
        store.upsertContact(normalized.sender, { pushName: msg.pushName });
      }
      // Store raw message so it can be forwarded, quoted, or (if media) downloaded.
      store.storeRawMessage(msg.key.id, msg);

      // Update chat activity. Name is intentionally NOT set here — it is resolved
      // at serve time by displayName(), which always picks the *other* party.
      store.upsertChat(jid, {
        lastMessage: { text: normalized.text, timestamp: normalized.timestamp, fromMe: normalized.fromMe },
        timestamp: normalized.timestamp,
        unreadCount: normalized.fromMe ? 0 : (store.chats.get(jid)?.unreadCount || 0) + 1,
      });

      broadcast('messages.upsert', {
        jid,
        message: normalized,
        type,
        name: displayName(jid),
      });
      // Keep the chat LIST live: refresh preview, timestamp, unread badge & order.
      scheduleChatsBroadcast();
      scheduleSave();
    }
  });

  sock.ev.on('messages.update', (updates) => {
    for (const update of updates) {
      const jid = update.key.remoteJid;
      if (!jid) continue;
      if (update.update?.status) {
        store.updateMessageStatus(jid, update.key.id, update.update.status);
        broadcast('messages.update', {
          jid,
          msgId: update.key.id,
          status: update.update.status,
        });
      }
    }
  });

  sock.ev.on('message-receipt.update', (updates) => {
    for (const update of updates) {
      const r = update.receipt || {};
      // Map the receipt to a WhatsApp status code (2=server, 3=delivered, 4=read,
      // 5=played) instead of always claiming "read".
      let status = null;
      if (r.playedTimestamp) status = 5;
      else if (r.readTimestamp) status = 4;
      else if (r.receiptTimestamp) status = 3;
      if (status != null) store.updateMessageStatus(update.key.remoteJid, update.key.id, status);
      broadcast('message-receipt.update', {
        jid: update.key.remoteJid,
        msgId: update.key.id,
        status,
        receipt: update.receipt,
      });
    }
  });

  // --- Chat events ---

  sock.ev.on('chats.upsert', (chats) => {
    for (const chat of chats) {
      store.upsertChat(chat.id, {
        name: chat.name || chat.id.split('@')[0],
        unreadCount: chat.unreadCount || 0,
        pinned: chat.pinned ? true : false,
        muted: chat.mute ? true : false,
        archived: chat.archived ? true : false,
        timestamp: chat.conversationTimestamp
          ? (chat.conversationTimestamp.low || chat.conversationTimestamp) * 1000
          : Date.now(),
      });
    }
    broadcast('chats.upsert', { chats: serializeChats() });
    scheduleSave();
  });

  sock.ev.on('chats.update', (updates) => {
    for (const update of updates) {
      if (!update.id) continue;
      const patch = {};
      if (update.unreadCount != null) patch.unreadCount = update.unreadCount;
      if (update.name) patch.name = update.name;
      if (update.pinned != null) patch.pinned = !!update.pinned;
      if (update.mute != null) patch.muted = !!update.mute;
      if (update.archived != null) patch.archived = !!update.archived;
      if (update.conversationTimestamp) {
        patch.timestamp = (update.conversationTimestamp.low || update.conversationTimestamp) * 1000;
      }
      store.upsertChat(update.id, patch);
    }
    scheduleChatsBroadcast();
    scheduleSave();
  });

  sock.ev.on('chats.delete', (jids) => {
    for (const jid of jids) store.chats.delete(jid);
    broadcast('chats.delete', { jids });
    scheduleSave();
  });

  // --- Contact events ---

  sock.ev.on('contacts.upsert', (contacts) => {
    for (const contact of contacts) ingestContact(contact);
    broadcast('contacts.upsert', { contacts: serializeContacts() });
    scheduleSave();
  });

  sock.ev.on('contacts.update', (updates) => {
    for (const update of updates) ingestContact(update);
    broadcast('contacts.update', { contacts: serializeContacts() });
  });

  // --- Group events ---

  sock.ev.on('groups.upsert', (groups) => {
    for (const group of groups) {
      store.upsertChat(group.id, {
        name: group.subject || group.id.split('@')[0],
        isGroup: true,
      });
    }
    broadcast('groups.upsert', { groups });
    scheduleSave();
  });

  sock.ev.on('groups.update', (updates) => {
    for (const update of updates) {
      if (update.subject) {
        store.upsertChat(update.id, { name: update.subject });
      }
    }
    broadcast('groups.update', { updates });
  });

  sock.ev.on('group-participants.update', (update) => {
    broadcast('groups.participants.update', update);
  });

  // --- Presence events ---

  sock.ev.on('presence.update', (update) => {
    // update = { id: jid, presences: { [participantJid]: { lastKnownPresence, lastSeen } } }
    const chatJid = update.id;
    if (update.presences) {
      for (const [pJid, pData] of Object.entries(update.presences)) {
        const type = pData.lastKnownPresence || 'unavailable';
        store.updatePresence(pJid, type);
      }
    }
    broadcast('presence.update', {
      jid: chatJid,
      presences: update.presences,
    });
  });

  // --- Messaging history (initial sync) ---

  sock.ev.on('messaging-history.set', ({ chats, contacts, messages, isLatest, syncType }) => {
    for (const chat of chats) {
      const patch = {
        unreadCount: chat.unreadCount || 0,
        pinned: chat.pinned ? true : false,
        muted: chat.mute ? true : false,
        archived: chat.archived ? true : false,
        timestamp: chat.conversationTimestamp
          ? (chat.conversationTimestamp.low || chat.conversationTimestamp) * 1000
          : (store.chats.get(chat.id)?.timestamp || 0),
      };
      // Only store a real name (not the JID-number fallback).
      if (chat.name && /\D/.test(chat.name)) patch.name = chat.name;
      store.upsertChat(chat.id, patch);
    }
    for (const contact of contacts) ingestContact(contact);
    const touched = new Set();
    for (const { messages: msgs } of messages) {
      for (const msg of msgs) {
        const jid = msg.key.remoteJid;
        if (!jid || jid === 'status@broadcast') continue;
        learnJidMapping(msg);
        if (!msg.key.fromMe && msg.pushName) {
          const s = msg.key.participant || msg.key.remoteJid;
          if (s) store.upsertContact(s, { pushName: msg.pushName });
        }
        const normalized = normalizeMessage(msg, jid);
        store.addMessage(jid, normalized);
        if (normalized.hasMedia) store.storeRawMessage(msg.key.id, msg);
        touched.add(jid);
      }
    }
    // History can arrive newest-first; keep each touched chat chronological.
    for (const jid of touched) store.sortChat(jid);
    broadcast('chats.upsert', { chats: serializeChats() });
    // Tell any open chat buffers that fresh history landed so they can reload.
    if (touched.size) broadcast('history.set', { jids: [...touched] });
    scheduleSave();
    logger.info({ chats: chats.length, contacts: contacts.length, msgChats: touched.size, syncType }, 'History sync');
  });
}

// ---------------------------------------------------------------------------
// Express REST API
// ---------------------------------------------------------------------------

const app = express();
app.use(express.json());

// CORS for local development
app.use((req, res, next) => {
  res.set('Access-Control-Allow-Origin', 'http://localhost:*');
  res.set('Access-Control-Allow-Methods', 'GET,POST,PATCH,DELETE,OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type,Authorization');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

// Bearer token authentication (optional — set WAEL_API_TOKEN to enable)
if (CONFIG.apiToken) {
  app.use('/api', (req, res, next) => {
    const auth = req.headers.authorization;
    if (!auth || auth !== `Bearer ${CONFIG.apiToken}`) {
      return res.status(401).json({ ok: false, error: 'Unauthorized' });
    }
    next();
  });
  logger.info('API token authentication enabled');
}

// Simple in-memory rate limiter (optional — set WAEL_RATE_LIMIT to enable)
if (CONFIG.rateLimit > 0) {
  const hits = new Map();
  setInterval(() => hits.clear(), 60000);
  app.use('/api', (req, res, next) => {
    const ip = req.ip;
    const count = (hits.get(ip) || 0) + 1;
    hits.set(ip, count);
    if (count > CONFIG.rateLimit) {
      return res.status(429).json({ ok: false, error: 'Rate limit exceeded' });
    }
    next();
  });
  logger.info({ limit: CONFIG.rateLimit }, 'Rate limiting enabled (req/min)');
}

fs.mkdirSync(CONFIG.mediaDir, { recursive: true });
const upload = multer({ dest: CONFIG.mediaDir });

// --- Helpers ---

function ensureConnected(req, res, next) {
  if (!sock || connectionState !== 'open') {
    return res.status(503).json({ ok: false, error: 'WhatsApp not connected' });
  }
  next();
}

function normalizeJid(number) {
  let jid = String(number || '').trim();
  // Already a fully-qualified JID (user, lid, group, broadcast, newsletter)?
  if (jid.includes('@')) return jid;
  // Otherwise treat as a phone number and build a user JID.
  return jid.replace(/[^0-9]/g, '') + '@s.whatsapp.net';
}

// Pretty-print a phone number: "+55 54 99324-2221"-ish, best-effort by length.
function formatPhone(digits) {
  if (!digits) return '';
  const d = String(digits).replace(/[^0-9]/g, '');
  if (d.length < 7) return '+' + d;
  // Group as +<country><area><rest> without locale assumptions beyond spacing.
  const cc = d.length > 11 ? d.slice(0, d.length - 10) : d.slice(0, 2);
  const rest = d.slice(cc.length);
  const mid = rest.slice(0, 2);
  const num = rest.slice(2);
  const split = num.length > 4 ? num.slice(0, num.length - 4) + '-' + num.slice(-4) : num;
  return `+${cc} ${mid} ${split}`.trim();
}

// Resolve the best display name for ANY chat jid. Never returns empty.
//  - groups  -> stored subject, else "Group"
//  - users   -> saved name / pushName / mapped-contact name
//               -> formatted phone number (self or LID-mapped)
//               -> raw handle as a last resort (always stable, never blank)
function displayName(jid) {
  if (!jid) return '';
  if (isJidGroup(jid)) return store.chats.get(jid)?.name || 'Group';
  if (jid === 'status@broadcast') return 'Status';
  const n = store.contactName(jid);
  if (n) return n;
  // Baileys sometimes carries the saved name on the chat object. Accept it only
  // if it isn't a bare digit string (those are JID/LID-number fallbacks).
  const cn = store.chats.get(jid) && store.chats.get(jid).name;
  if (cn && /\D/.test(cn)) return cn;
  const pn = store.phoneJid(jid) || (jid.endsWith('@s.whatsapp.net') ? jid : null);
  if (pn) return formatPhone(pn.split('@')[0]);
  // Pure LID with no mapping and no name: show its handle so it's still openable.
  return jid.split('@')[0];
}

// Learn LID<->phone mappings from the alternate-JID fields WhatsApp puts on
// message keys (senderPn/senderLid/participantPn). Each one we capture lets a
// future @lid chat resolve to a real contact name + phone number.
function learnJidMapping(msg) {
  const k = (msg && msg.key) || {};
  if (k.remoteJid && k.remoteJid.endsWith('@lid') && k.senderPn) store.recordJidMapping(k.remoteJid, k.senderPn);
  if (k.participant && k.participant.endsWith('@lid') && k.participantPn) store.recordJidMapping(k.participant, k.participantPn);
  if (k.senderLid && k.senderPn) store.recordJidMapping(k.senderLid, k.senderPn);
  if (msg && msg.senderLid && msg.senderPn) store.recordJidMapping(msg.senderLid, msg.senderPn);
}

// Reconstruct a correct Baileys message key from the store, including the
// `participant` (required for read/revoke/edit in groups & @lid chats) and the
// real `fromMe` flag, instead of hard-coding fromMe:true.
function messageKey(jid, msgId) {
  const arr = store.messages.get(jid) || [];
  const m = arr.find(x => x.id === msgId);
  const key = { remoteJid: jid, id: msgId, fromMe: m ? !!m.fromMe : false };
  if (isJidGroup(jid) && m && m.sender) key.participant = m.sender;
  return key;
}

// Build sendMessage options for quoting a message. Prefer the full raw message
// (so media/polls/etc. quote correctly); otherwise reconstruct a minimal quote.
function quotedOptions(jid, quotedMsgId) {
  if (!quotedMsgId) return {};
  const raw = store.getRawMessage(quotedMsgId);
  if (raw && raw.message) return { quoted: raw };
  const m = (store.messages.get(jid) || []).find(x => x.id === quotedMsgId);
  if (!m) return {};
  return {
    quoted: {
      key: { remoteJid: jid, id: quotedMsgId, fromMe: !!m.fromMe, participant: m.sender },
      message: { conversation: m.text || '' },
    },
  };
}

// Ingest a Baileys Contact: record its LID<->phone mapping and store its name
// under both the lid and phone JIDs so a lookup by either key resolves.
function ingestContact(c) {
  if (!c || !c.id) return;
  if (c.lid && c.jid) store.recordJidMapping(c.lid, c.jid);
  if (c.id.endsWith('@lid') && c.jid) store.recordJidMapping(c.id, c.jid);
  if (c.id.endsWith('@s.whatsapp.net') && c.lid) store.recordJidMapping(c.lid, c.id);
  const patch = {};
  if (c.name) patch.name = c.name;
  if (c.notify) patch.pushName = c.notify;
  if (c.imgUrl && c.imgUrl !== 'changed') patch.imgUrl = c.imgUrl;
  store.upsertContact(c.id, patch);
  if (Object.keys(patch).length) {
    const pn = store.phoneJid(c.id);
    if (pn && pn !== c.id) store.upsertContact(pn, patch);
  }
}

// Contacts with resolved display name + phone, for API responses & broadcasts.
function serializeContacts() {
  return [...store.contacts.values()].map(c => ({
    ...c,
    name: displayName(c.jid),
    phone: (store.phoneJid(c.jid) || (c.jid.endsWith('@s.whatsapp.net') ? c.jid : '')).split('@')[0] || '',
  }));
}

// Chats with resolved display name + phone + presence, for API & broadcasts.
function serializeChats() {
  return [...store.chats.values()].map(chat => {
    const msgs = store.messages.get(chat.jid);
    const last = chat.lastMessage || (msgs && msgs.length
      ? { text: msgs[msgs.length - 1].text, timestamp: msgs[msgs.length - 1].timestamp, fromMe: msgs[msgs.length - 1].fromMe }
      : null);
    // Many persisted chats have timestamp:0; fall back to the last message so the
    // list stays sorted by recency after a restart.
    const timestamp = chat.timestamp || (last && last.timestamp) || 0;
    return {
      ...chat,
      name: displayName(chat.jid),
      phone: (store.phoneJid(chat.jid) || (chat.jid.endsWith('@s.whatsapp.net') ? chat.jid : '')).split('@')[0] || '',
      lid: chat.jid.endsWith('@lid') ? chat.jid : (store.pnToLid.get(chat.jid) || ''),
      lastMessage: last,
      timestamp,
      presence: store.getPresence(chat.jid),
    };
  });
}

// On connect, group chats have no subject and contacts are sparse. Fetch group
// metadata to (1) fill in the group name and (2) harvest the participants'
// LID<->phone mappings — the richest source of mappings WhatsApp gives us.
let backfillRunning = false;
async function backfillGroupMetadata() {
  if (backfillRunning || !sock || connectionState !== 'open') return;
  backfillRunning = true;
  try {
    let updated = 0;
    // One round-trip fetches every group we participate in — subjects + the
    // full participant list (each carries id/lid + phone jid: our richest map).
    let groups = {};
    try { groups = await sock.groupFetchAllParticipating(); } catch (e) { logger.warn({ e: e.message }, 'groupFetchAllParticipating failed'); }
    for (const g of Object.values(groups || {})) {
      if (!g || !g.id) continue;
      store.upsertChat(g.id, { name: g.subject || store.chats.get(g.id)?.name || '', isGroup: true });
      if (g.subject) updated++;
      for (const p of g.participants || []) {
        if (p.lid && p.jid) store.recordJidMapping(p.lid, p.jid);
        if (p.id && p.id.endsWith('@lid') && p.jid) store.recordJidMapping(p.id, p.jid);
      }
    }
    if (updated || Object.keys(groups || {}).length) {
      store.save();
      broadcast('chats.update', { chats: serializeChats() });
      broadcast('contacts.update', { contacts: serializeContacts() });
      logger.info({ groups: Object.keys(groups || {}).length, named: updated, lidMap: store.lidToPn.size }, 'Group metadata backfilled');
    }
  } finally {
    backfillRunning = false;
  }
}

// --- Session ---

app.get('/api/v1/session/status', (req, res) => {
  res.json({
    ok: true,
    data: {
      state: connectionState,
      hasQR: !!currentQR,
      user: sock?.user
        ? { id: jidNormalizedUser(sock.user.id), name: sock.user.name }
        : null,
    },
  });
});

app.get('/api/v1/session/qr', async (req, res) => {
  if (!currentQR) {
    return res.json({ ok: false, error: 'No QR code available', state: connectionState });
  }
  try {
    const fmt = req.query.format || 'base64';
    if (fmt === 'png') {
      const buf = await QRCode.toBuffer(currentQR, { width: 256, type: 'png' });
      res.set('Content-Type', 'image/png');
      return res.send(buf);
    }
    const dataUrl = await QRCode.toDataURL(currentQR, { width: 256 });
    res.json({ ok: true, data: { qr: dataUrl } });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/v1/session/me', ensureConnected, (req, res) => {
  const user = sock.user;
  res.json({
    ok: true,
    data: {
      jid: jidNormalizedUser(user.id),
      name: user.name,
    },
  });
});

app.post('/api/v1/session/logout', async (req, res) => {
  try {
    if (sock) await sock.logout();
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// --- Chats ---

app.get('/api/v1/chats', ensureConnected, (req, res) => {
  const chats = serializeChats().sort((a, b) => {
    // Pinned first, then by timestamp descending
    if (a.pinned && !b.pinned) return -1;
    if (!a.pinned && b.pinned) return 1;
    return (b.timestamp || 0) - (a.timestamp || 0);
  });
  res.json({ ok: true, data: chats });
});

// --- Contacts ---

app.get('/api/v1/contacts', ensureConnected, (req, res) => {
  res.json({ ok: true, data: serializeContacts() });
});

app.get('/api/v1/contacts/:jid', ensureConnected, async (req, res) => {
  const jid = normalizeJid(req.params.jid);
  const contact = store.contacts.get(jid) || { jid };
  // Fetch status/about text
  try {
    const status = await sock.fetchStatus(jid);
    if (status) contact.status = status.status;
  } catch {}
  // Fetch profile pic URL
  try {
    const ppUrl = await sock.profilePictureUrl(jid, 'preview');
    if (ppUrl) contact.imgUrl = ppUrl;
  } catch {}
  res.json({ ok: true, data: contact });
});

// --- Messages ---

app.post('/api/v1/messages/send/text', ensureConnected, async (req, res) => {
  try {
    const { jid, number, text, quotedMsgId } = req.body;
    const target = normalizeJid(jid || number || '');
    if (!target || !text) {
      return res.status(400).json({ ok: false, error: 'Missing jid/number and text' });
    }

    const opts = quotedOptions(target, quotedMsgId);

    const sent = await sock.sendMessage(target, { text }, opts);
    const normalized = normalizeMessage(
      { ...sent, pushName: sock.user?.name || 'me' },
      target
    );
    store.addMessage(target, normalized);
    store.storeRawMessage(normalized.id, sent);
    store.upsertChat(target, {
      lastMessage: { text, timestamp: normalized.timestamp, fromMe: true },
      timestamp: normalized.timestamp,
    });
    scheduleChatsBroadcast();
    scheduleSave();

    res.json({ ok: true, data: normalized });
  } catch (err) {
    logger.error({ err }, 'Send text failed');
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/v1/messages/send/media', ensureConnected, upload.single('file'), async (req, res) => {
  try {
    const { jid, number, caption, mimetype } = req.body;
    const target = normalizeJid(jid || number || '');
    if (!target || !req.file) {
      return res.status(400).json({ ok: false, error: 'Missing jid/number and file' });
    }

    const filePath = req.file.path;
    const mime = mimetype || req.file.mimetype || 'application/octet-stream';
    const fileName = req.file.originalname || 'file';

    const isPtt = req.body.ptt === 'true' || req.body.ptt === true || (mime.startsWith('audio/') && /ogg|opus/.test(mime));
    let msgContent;
    if (mime.startsWith('image/')) {
      msgContent = { image: fs.readFileSync(filePath), caption: caption || undefined, mimetype: mime };
    } else if (mime.startsWith('video/')) {
      msgContent = { video: fs.readFileSync(filePath), caption: caption || undefined, mimetype: mime };
    } else if (mime.startsWith('audio/')) {
      msgContent = { audio: fs.readFileSync(filePath), mimetype: mime, ptt: isPtt };
    } else {
      msgContent = { document: fs.readFileSync(filePath), mimetype: mime, fileName };
    }

    const sent = await sock.sendMessage(target, msgContent);
    // Clean up temp file
    fs.unlink(filePath, () => {});

    const normalized = normalizeMessage(
      { ...sent, pushName: sock.user?.name || 'me' },
      target
    );
    store.addMessage(target, normalized);
    // Keep raw so our own media can be re-downloaded later.
    store.storeRawMessage(normalized.id, sent);
    store.upsertChat(target, {
      lastMessage: { text: normalized.text, timestamp: normalized.timestamp, fromMe: true },
      timestamp: normalized.timestamp,
    });
    scheduleChatsBroadcast();
    scheduleSave();

    res.json({ ok: true, data: normalized });
  } catch (err) {
    logger.error({ err }, 'Send media failed');
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/v1/messages/react', ensureConnected, async (req, res) => {
  try {
    const { jid, msgId, emoji } = req.body;
    if (!jid || !msgId) {
      return res.status(400).json({ ok: false, error: 'Missing jid and msgId' });
    }
    await sock.sendMessage(jid, {
      react: { text: emoji || '', key: { remoteJid: jid, id: msgId } },
    });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/v1/messages/reply', ensureConnected, async (req, res) => {
  try {
    const { jid, text, quotedMsgId } = req.body;
    if (!jid || !text || !quotedMsgId) {
      return res.status(400).json({ ok: false, error: 'Missing jid, text, and quotedMsgId' });
    }
    const target = normalizeJid(jid);
    const sent = await sock.sendMessage(target, { text }, quotedOptions(target, quotedMsgId));
    const normalized = normalizeMessage({ ...sent, pushName: sock.user?.name || 'me' }, target);
    store.addMessage(target, normalized);
    store.storeRawMessage(normalized.id, sent);
    store.upsertChat(target, {
      lastMessage: { text, timestamp: normalized.timestamp, fromMe: true },
      timestamp: normalized.timestamp,
    });
    scheduleChatsBroadcast();
    scheduleSave();
    res.json({ ok: true, data: normalized });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/v1/messages/delete', ensureConnected, async (req, res) => {
  try {
    const { jid, msgId, forEveryone } = req.body;
    if (!jid || !msgId) {
      return res.status(400).json({ ok: false, error: 'Missing jid and msgId' });
    }
    if (forEveryone) {
      await sock.sendMessage(jid, { delete: messageKey(jid, msgId) });
    } else {
      const m = (store.messages.get(jid) || []).find(x => x.id === msgId);
      await sock.chatModify({ clear: { messages: [{ id: msgId, fromMe: m ? !!m.fromMe : true, timestamp: m ? Math.floor(m.timestamp / 1000) : Math.floor(Date.now() / 1000) }] } }, jid);
    }
    store.deleteMessage(jid, msgId);
    broadcast('messages.delete', { jid, msgId });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/v1/messages/read', ensureConnected, async (req, res) => {
  try {
    const { jid, msgIds } = req.body;
    if (!jid) return res.status(400).json({ ok: false, error: 'Missing jid' });
    // Read-receipt keys need participant+fromMe in groups/@lid chats. If no
    // explicit ids were given, mark the most recent inbound messages read.
    let ids = msgIds;
    if (!ids || ids.length === 0) {
      ids = (store.messages.get(jid) || []).filter(m => !m.fromMe).slice(-20).map(m => m.id);
    }
    const keys = ids.map(id => messageKey(jid, id));
    if (keys.length > 0) {
      await sock.readMessages(keys);
    }
    store.upsertChat(jid, { unreadCount: 0 });
    broadcast('chats.update', { chats: serializeChats() });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/v1/messages/history/:jid', ensureConnected, (req, res) => {
  const jid = normalizeJid(req.params.jid);
  const limit = parseInt(req.query.limit || '50', 10);
  const before = req.query.before || null;
  const messages = store.getMessages(jid, limit, before).map(msg => ({
    ...msg,
    reactions: store.getReactions(msg.id),
    starred: store.starred.has(msg.id),
  }));
  res.json({ ok: true, data: messages, total: (store.messages.get(jid) || []).length });
});

// On-demand: ask WhatsApp for older messages preceding what we have. Results
// arrive asynchronously via messaging-history.set -> broadcast('history.set').
app.post('/api/v1/messages/history/:jid/fetch', ensureConnected, async (req, res) => {
  try {
    const jid = normalizeJid(req.params.jid);
    const count = Math.min(parseInt(req.body.count || '50', 10), 50);
    const arr = store.messages.get(jid) || [];
    if (arr.length === 0) {
      return res.json({ ok: true, data: { requested: false, reason: 'no anchor message to page from yet' } });
    }
    const oldest = arr[0];
    const ts = Math.floor((oldest.timestamp || Date.now()) / 1000);
    await sock.fetchMessageHistory(count, messageKey(jid, oldest.id), ts);
    res.json({ ok: true, data: { requested: true } });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/v1/messages/search', ensureConnected, (req, res) => {
  const { q, jid, limit: limitStr } = req.query;
  const limit = parseInt(limitStr || '20', 10);
  if (!q) return res.status(400).json({ ok: false, error: 'Missing query parameter q' });

  const results = [];
  const searchLower = q.toLowerCase();
  const jids = jid ? [normalizeJid(jid)] : [...store.messages.keys()];

  for (const chatJid of jids) {
    const msgs = store.messages.get(chatJid) || [];
    for (const msg of msgs) {
      if (msg.text && msg.text.toLowerCase().includes(searchLower)) {
        results.push(msg);
        if (results.length >= limit) break;
      }
    }
    if (results.length >= limit) break;
  }

  res.json({ ok: true, data: results });
});

// --- Presence ---

app.post('/api/v1/presence/update', ensureConnected, async (req, res) => {
  try {
    const { jid, type } = req.body;
    if (!jid || !type) {
      return res.status(400).json({ ok: false, error: 'Missing jid and type' });
    }
    await sock.sendPresenceUpdate(type, jid);
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/v1/presence/subscribe', ensureConnected, async (req, res) => {
  try {
    const { jid } = req.body;
    if (!jid) return res.status(400).json({ ok: false, error: 'Missing jid' });
    await sock.presenceSubscribe(jid);
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/v1/presence/:jid', ensureConnected, (req, res) => {
  const jid = normalizeJid(req.params.jid);
  const presence = store.getPresence(jid);
  res.json({ ok: true, data: presence });
});

// --- Message edit ---

app.post('/api/v1/messages/edit', ensureConnected, async (req, res) => {
  try {
    const { jid, msgId, newText } = req.body;
    if (!jid || !msgId || !newText) {
      return res.status(400).json({ ok: false, error: 'Missing jid, msgId, and newText' });
    }
    // Use a proper key (participant in groups) so edits to our own group
    // messages aren't rejected.
    await sock.sendMessage(jid, { text: newText, edit: messageKey(jid, msgId) });
    // Update in store
    const arr = store.messages.get(jid) || [];
    const msg = arr.find(m => m.id === msgId);
    if (msg) {
      msg.text = newText;
      msg.edited = true;
    }
    const payload = msg || { id: msgId, jid, text: newText, edited: true, fromMe: true };
    broadcast('messages.edit', { jid, message: payload });
    res.json({ ok: true, data: payload });
  } catch (err) {
    logger.error({ err }, 'Edit message failed');
    res.status(500).json({ ok: false, error: err.message });
  }
});

// --- Media download ---

app.get('/api/v1/messages/media/:msgId', ensureConnected, async (req, res) => {
  try {
    const safeId = String(req.params.msgId).replace(/[^A-Za-z0-9_-]/g, '_');
    const cacheBase = path.join(CONFIG.mediaDir, 'cache');
    fs.mkdirSync(cacheBase, { recursive: true });
    // Serve from disk if we already downloaded this media once — so it survives a
    // bridge restart even after the raw message has aged out of the cache.
    const metaPath = path.join(cacheBase, safeId + '.json');
    const dataPath = path.join(cacheBase, safeId + '.bin');
    if (fs.existsSync(dataPath) && fs.existsSync(metaPath)) {
      const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
      res.set('Content-Type', meta.mime || 'application/octet-stream');
      res.set('Content-Disposition', `attachment; filename="${meta.fileName || safeId}"`);
      return res.send(fs.readFileSync(dataPath));
    }
    const rawMsg = store.getRawMessage(req.params.msgId);
    if (!rawMsg || !rawMsg.message) {
      return res.status(404).json({ ok: false, error: 'Media message not found or expired from cache' });
    }
    const buffer = await downloadMediaMessage(rawMsg, 'buffer', {}, {
      logger: baileysLogger,
      reuploadRequest: sock.updateMediaMessage,
    });
    const contentType = getContentType(rawMsg.message);
    const content = rawMsg.message[contentType];
    const mime = content?.mimetype || 'application/octet-stream';
    const fileName = content?.fileName || `media-${safeId}`;
    // Persist to disk for next time (best-effort).
    try {
      fs.writeFileSync(dataPath, buffer);
      fs.writeFileSync(metaPath, JSON.stringify({ mime, fileName }));
    } catch (e) { logger.warn({ e: e.message }, 'media cache write failed'); }
    res.set('Content-Type', mime);
    res.set('Content-Disposition', `attachment; filename="${fileName}"`);
    res.send(buffer);
  } catch (err) {
    logger.error({ err }, 'Media download failed');
    res.status(500).json({ ok: false, error: err.message });
  }
});

// --- Send location ---

app.post('/api/v1/messages/send/location', ensureConnected, async (req, res) => {
  try {
    const { jid, lat, lon, name, address } = req.body;
    const target = normalizeJid(jid || '');
    if (!target || lat == null || lon == null) {
      return res.status(400).json({ ok: false, error: 'Missing jid, lat, lon' });
    }
    const sent = await sock.sendMessage(target, {
      location: { degreesLatitude: lat, degreesLongitude: lon, name: name || undefined, address: address || undefined },
    });
    const normalized = normalizeMessage({ ...sent, pushName: sock.user?.name || 'me' }, target);
    store.addMessage(target, normalized);
    res.json({ ok: true, data: normalized });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// --- Send contact vCard ---

app.post('/api/v1/messages/send/contact', ensureConnected, async (req, res) => {
  try {
    const { jid, displayName, vcard } = req.body;
    const target = normalizeJid(jid || '');
    if (!target || !displayName || !vcard) {
      return res.status(400).json({ ok: false, error: 'Missing jid, displayName, vcard' });
    }
    const sent = await sock.sendMessage(target, {
      contacts: { displayName, contacts: [{ vcard }] },
    });
    const normalized = normalizeMessage({ ...sent, pushName: sock.user?.name || 'me' }, target);
    store.addMessage(target, normalized);
    res.json({ ok: true, data: normalized });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// --- Send poll ---

app.post('/api/v1/messages/send/poll', ensureConnected, async (req, res) => {
  try {
    const { jid, name, values, selectableCount } = req.body;
    const target = normalizeJid(jid || '');
    if (!target || !name || !values || !Array.isArray(values) || values.length < 2) {
      return res.status(400).json({ ok: false, error: 'Missing jid, name, values (array, min 2)' });
    }
    const sent = await sock.sendMessage(target, {
      poll: { name, values, selectableCount: selectableCount || 1 },
    });
    const normalized = normalizeMessage({ ...sent, pushName: sock.user?.name || 'me' }, target);
    store.addMessage(target, normalized);
    res.json({ ok: true, data: normalized });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// --- Forward message ---

app.post('/api/v1/messages/forward', ensureConnected, async (req, res) => {
  try {
    const { fromJid, toJid, msgId } = req.body;
    if (!fromJid || !toJid || !msgId) {
      return res.status(400).json({ ok: false, error: 'Missing fromJid, toJid, msgId' });
    }
    const rawMsg = store.getRawMessage(msgId);
    const target = normalizeJid(toJid);
    if (rawMsg) {
      // Forward the original message
      await sock.sendMessage(target, { forward: rawMsg });
    } else {
      // Fallback: send as text
      const msgs = store.messages.get(normalizeJid(fromJid)) || [];
      const msg = msgs.find(m => m.id === msgId);
      if (!msg) return res.status(404).json({ ok: false, error: 'Message not found' });
      await sock.sendMessage(target, { text: msg.text });
    }
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// --- Contact avatar ---

app.get('/api/v1/contacts/:jid/avatar', ensureConnected, async (req, res) => {
  try {
    const jid = normalizeJid(req.params.jid);
    const url = await sock.profilePictureUrl(jid, 'image');
    if (req.query.redirect === 'true' && url) {
      return res.redirect(url);
    }
    res.json({ ok: true, data: { url: url || null } });
  } catch (err) {
    // No profile picture available
    if (err.message?.includes('not-authorized') || err.message?.includes('item-not-found')) {
      return res.json({ ok: true, data: { url: null } });
    }
    res.status(500).json({ ok: false, error: err.message });
  }
});

// --- Chat management ---

app.post('/api/v1/chats/archive', ensureConnected, async (req, res) => {
  try {
    const { jid, archive } = req.body;
    if (!jid) return res.status(400).json({ ok: false, error: 'Missing jid' });
    const lastMsg = store.messages.get(jid)?.slice(-1)[0];
    await sock.chatModify({
      archive: archive !== false,
      lastMessages: lastMsg ? [{ key: { remoteJid: jid, id: lastMsg.id, fromMe: lastMsg.fromMe }, messageTimestamp: Math.floor(lastMsg.timestamp / 1000) }] : [],
    }, jid);
    store.upsertChat(jid, { archived: archive !== false });
    broadcast('chats.update', { chats: serializeChats() });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/v1/chats/mute', ensureConnected, async (req, res) => {
  try {
    const { jid, mute, duration } = req.body;
    if (!jid) return res.status(400).json({ ok: false, error: 'Missing jid' });
    const muteExpiry = mute !== false
      ? Math.floor(Date.now() / 1000) + (duration || 8 * 60 * 60) // default 8 hours
      : 0;
    await sock.chatModify({ mute: muteExpiry || null }, jid);
    store.upsertChat(jid, { muted: mute !== false });
    broadcast('chats.update', { chats: serializeChats() });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/v1/chats/pin', ensureConnected, async (req, res) => {
  try {
    const { jid, pin } = req.body;
    if (!jid) return res.status(400).json({ ok: false, error: 'Missing jid' });
    await sock.chatModify({ pin: pin !== false }, jid);
    store.upsertChat(jid, { pinned: pin !== false });
    broadcast('chats.update', { chats: serializeChats() });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.delete('/api/v1/chats/:jid', ensureConnected, async (req, res) => {
  try {
    const jid = normalizeJid(req.params.jid);
    const lastMsg = store.messages.get(jid)?.slice(-1)[0];
    await sock.chatModify({
      delete: true,
      lastMessages: lastMsg ? [{ key: { remoteJid: jid, id: lastMsg.id, fromMe: lastMsg.fromMe }, messageTimestamp: Math.floor(lastMsg.timestamp / 1000) }] : [],
    }, jid);
    store.chats.delete(jid);
    store.messages.delete(jid);
    broadcast('chats.delete', { jids: [jid] });
    store.save();
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// --- Groups ---

app.get('/api/v1/groups/:jid/metadata', ensureConnected, async (req, res) => {
  try {
    const metadata = await sock.groupMetadata(req.params.jid);
    res.json({ ok: true, data: metadata });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/v1/groups/create', ensureConnected, async (req, res) => {
  try {
    const { name, participants } = req.body;
    if (!name || !participants || !Array.isArray(participants) || participants.length === 0) {
      return res.status(400).json({ ok: false, error: 'Missing name and participants array' });
    }
    const jids = participants.map(p => normalizeJid(p));
    const group = await sock.groupCreate(name, jids);
    store.upsertChat(group.id, { name, isGroup: true, timestamp: Date.now() });
    store.save();
    res.json({ ok: true, data: group });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.patch('/api/v1/groups/:jid', ensureConnected, async (req, res) => {
  try {
    const { subject, description } = req.body;
    if (subject) await sock.groupUpdateSubject(req.params.jid, subject);
    if (description !== undefined) await sock.groupUpdateDescription(req.params.jid, description || '');
    if (subject) store.upsertChat(req.params.jid, { name: subject });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/v1/groups/:jid/participants', ensureConnected, async (req, res) => {
  try {
    const { action, participants } = req.body;
    if (!action || !participants || !Array.isArray(participants)) {
      return res.status(400).json({ ok: false, error: 'Missing action and participants' });
    }
    const jids = participants.map(p => normalizeJid(p));
    let result;
    switch (action) {
      case 'add':     result = await sock.groupParticipantsUpdate(req.params.jid, jids, 'add'); break;
      case 'remove':  result = await sock.groupParticipantsUpdate(req.params.jid, jids, 'remove'); break;
      case 'promote': result = await sock.groupParticipantsUpdate(req.params.jid, jids, 'promote'); break;
      case 'demote':  result = await sock.groupParticipantsUpdate(req.params.jid, jids, 'demote'); break;
      default: return res.status(400).json({ ok: false, error: 'Invalid action: add|remove|promote|demote' });
    }
    res.json({ ok: true, data: result });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/v1/groups/:jid/leave', ensureConnected, async (req, res) => {
  try {
    await sock.groupLeave(req.params.jid);
    store.chats.delete(req.params.jid);
    broadcast('chats.delete', { jids: [req.params.jid] });
    store.save();
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/v1/groups/:jid/invite-code', ensureConnected, async (req, res) => {
  try {
    const code = await sock.groupInviteCode(req.params.jid);
    res.json({ ok: true, data: { code, link: `https://chat.whatsapp.com/${code}` } });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// --- Starred messages ---

app.post('/api/v1/messages/star', ensureConnected, (req, res) => {
  const { msgId, star } = req.body;
  if (!msgId) return res.status(400).json({ ok: false, error: 'Missing msgId' });
  if (star !== false) {
    store.starred.add(msgId);
  } else {
    store.starred.delete(msgId);
  }
  broadcast('messages.star', { msgId, starred: store.starred.has(msgId) });
  res.json({ ok: true });
});

app.get('/api/v1/messages/starred', ensureConnected, (req, res) => {
  const results = [];
  for (const [jid, msgs] of store.messages) {
    for (const msg of msgs) {
      if (store.starred.has(msg.id)) {
        results.push({ ...msg, reactions: store.getReactions(msg.id) });
      }
    }
  }
  res.json({ ok: true, data: results });
});

// --- Mark all chats read ---

app.post('/api/v1/chats/read-all', ensureConnected, async (req, res) => {
  try {
    for (const [jid, chat] of store.chats) {
      if (chat.unreadCount > 0) {
        const msgs = store.messages.get(jid) || [];
        const lastMsg = msgs[msgs.length - 1];
        if (lastMsg) {
          await sock.readMessages([{ remoteJid: jid, id: lastMsg.id }]);
        }
        store.upsertChat(jid, { unreadCount: 0 });
      }
    }
    broadcast('chats.update', { chats: serializeChats() });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// --- Profile picture batch ---

app.get('/api/v1/contacts/avatars', ensureConnected, async (req, res) => {
  const jids = (req.query.jids || '').split(',').filter(Boolean);
  const results = {};
  for (const jid of jids.slice(0, 20)) { // max 20 per request
    try {
      const url = await sock.profilePictureUrl(normalizeJid(jid), 'preview');
      results[jid] = url;
    } catch {
      results[jid] = null;
    }
  }
  res.json({ ok: true, data: results });
});

// --- Chat export ---

app.get('/api/v1/chats/:jid/export', ensureConnected, (req, res) => {
  const jid = normalizeJid(req.params.jid);
  const format = req.query.format || 'text'; // text or json
  const limit = parseInt(req.query.limit || '500', 10);
  const messages = store.getMessages(jid, limit, null);
  const chatName = store.chats.get(jid)?.name || jid;

  if (format === 'json') {
    return res.json({ ok: true, data: { chatName, jid, messages, exportedAt: Date.now() } });
  }

  // Plain text export
  let text = `WhatsApp Chat Export: ${chatName}\n`;
  text += `JID: ${jid}\n`;
  text += `Exported: ${new Date().toISOString()}\n`;
  text += `Messages: ${messages.length}\n`;
  text += '─'.repeat(60) + '\n\n';

  for (const msg of messages) {
    if (msg.deleted) continue;
    const date = new Date(msg.timestamp);
    const dateStr = date.toLocaleString();
    const sender = msg.fromMe ? 'You' : (msg.senderName || msg.sender?.split('@')[0] || '?');
    let body = msg.text || '';
    if (msg.type !== 'text') body = `[${msg.type}] ${body}`;
    text += `[${dateStr}] ${sender}: ${body}\n`;
  }

  res.set('Content-Type', 'text/plain; charset=utf-8');
  res.set('Content-Disposition', `attachment; filename="whatsapp-${chatName.replace(/[^a-zA-Z0-9]/g, '_')}.txt"`);
  res.send(text);
});

// --- In-chat search ---

app.get('/api/v1/status', ensureConnected, (req, res) => {
  res.json({ ok: true, data: store.statusUpdates });
});

app.get('/api/v1/messages/search/chat/:jid', ensureConnected, (req, res) => {
  const jid = normalizeJid(req.params.jid);
  const { q, limit: limitStr } = req.query;
  const limit = parseInt(limitStr || '20', 10);
  if (!q) return res.status(400).json({ ok: false, error: 'Missing q' });
  const msgs = store.messages.get(jid) || [];
  const needle = q.toLowerCase();
  const results = msgs.filter(m => m.text && m.text.toLowerCase().includes(needle)).slice(-limit);
  res.json({ ok: true, data: results });
});

// --- Chat stats ---

app.get('/api/v1/chats/:jid/stats', ensureConnected, (req, res) => {
  const jid = normalizeJid(req.params.jid);
  const msgs = store.messages.get(jid) || [];
  const chat = store.chats.get(jid);
  const senderCounts = {};
  let mediaCount = 0;
  for (const m of msgs) {
    if (m.deleted) continue;
    const sender = m.fromMe ? 'you' : (m.senderName || m.sender || '?');
    senderCounts[sender] = (senderCounts[sender] || 0) + 1;
    if (m.hasMedia) mediaCount++;
  }
  res.json({ ok: true, data: {
    jid,
    name: chat?.name || jid,
    totalMessages: msgs.length,
    mediaCount,
    senderCounts,
    firstMessage: msgs[0]?.timestamp || null,
    lastMessage: msgs[msgs.length - 1]?.timestamp || null,
  }});
});

// --- Health check ---

app.get('/api/v1/health', (req, res) => {
  res.json({ ok: true, uptime: process.uptime(), state: connectionState });
});

// ---------------------------------------------------------------------------
// Start servers
// ---------------------------------------------------------------------------

const httpServer = http.createServer(app);

// WebSocket on separate port
wss = new WebSocketServer({ port: CONFIG.wsPort });
wss.on('connection', (ws, req) => {
  // Token auth for WebSocket (pass as ?token=xxx query param)
  if (CONFIG.apiToken) {
    const url = new URL(req.url, `http://localhost:${CONFIG.wsPort}`);
    const token = url.searchParams.get('token');
    if (token !== CONFIG.apiToken) {
      ws.close(4001, 'Unauthorized');
      logger.warn('WS client rejected: bad token');
      return;
    }
  }

  wsClients.add(ws);
  logger.info(`WS client connected (total: ${wsClients.size})`);

  // Send current state on connect
  ws.send(JSON.stringify({
    event: 'connection.update',
    data: {
      state: connectionState,
      hasQR: !!currentQR,
      user: sock?.user
        ? { id: jidNormalizedUser(sock.user.id), name: sock.user.name }
        : null,
    },
    ts: Date.now(),
  }));

  // Send current chat list
  if (store.chats.size > 0) {
    ws.send(JSON.stringify({
      event: 'chats.upsert',
      data: { chats: serializeChats() },
      ts: Date.now(),
    }));
  }

  ws.on('close', () => {
    wsClients.delete(ws);
    logger.info(`WS client disconnected (total: ${wsClients.size})`);
  });

  ws.on('error', (err) => {
    logger.warn({ err }, 'WS client error');
    wsClients.delete(ws);
  });
});

httpServer.listen(CONFIG.port, () => {
  logger.info(`REST API on http://localhost:${CONFIG.port}`);
  logger.info(`WebSocket on ws://localhost:${CONFIG.wsPort}`);
  if (CONFIG.apiToken) logger.info('Auth: bearer token enabled');
  if (CONFIG.rateLimit > 0) logger.info({ limit: CONFIG.rateLimit }, 'Rate limit: req/min');
  startSock().catch(err => {
    logger.error({ err }, 'Failed to start WhatsApp connection');
  });
});

// --- WebSocket heartbeat (detect stale clients) ---

const WS_PING_INTERVAL = 30000;
const wsAlive = new WeakMap();
setInterval(() => {
  for (const client of wsClients) {
    if (wsAlive.get(client) === false) {
      client.terminate();
      wsClients.delete(client);
      continue;
    }
    wsAlive.set(client, false);
    client.ping();
  }
}, WS_PING_INTERVAL);

wss.on('connection', (ws) => {
  wsAlive.set(ws, true);
  ws.on('pong', () => wsAlive.set(ws, true));
});

// --- Auto-save store every 5 minutes ---

setInterval(() => {
  store.save();
  // Prune old reactions (keep last 1000)
  if (store.reactions.size > 1000) {
    const keys = [...store.reactions.keys()];
    for (let i = 0; i < keys.length - 1000; i++) {
      store.reactions.delete(keys[i]);
    }
  }
}, 300000);

// --- Graceful shutdown ---

async function shutdown(signal) {
  logger.info({ signal }, 'Shutting down...');
  store.save();
  if (sock) {
    try { sock.end(); } catch {}
  }
  wss.close();
  httpServer.close();
  process.exit(0);
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('unhandledRejection', (err) => {
  logger.error({ err }, 'Unhandled rejection');
});
