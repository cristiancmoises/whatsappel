import express from "express"
import bodyParser from "body-parser"
import makeWASocket, {
  useMultiFileAuthState,
  DisconnectReason,
  fetchLatestBaileysVersion
} from "@whiskeysockets/baileys"
import qrcode from "qrcode-terminal"
import P from "pino"
import fs from "fs"

const app = express()
const PORT = 3000
app.use(bodyParser.json())

let messages = [] // store last received messages in memory

// Root endpoint
app.get("/", (req, res) => res.send("✅ WhatsApp API running"))

// Get recent messages
app.get("/messages", (req, res) => {
  res.send(messages.slice(-50)) // last 50 messages
})

// Send text / image / file / gif
app.post("/send", async (req, res) => {
  const { to, text, image, file, gif } = req.body
  if (!to) return res.status(400).send({ error: "Missing 'to'" })

  try {
    if (!global.sock)
      return res.status(500).send({ error: "WhatsApp not connected" })

    const jid = to.includes("@s.whatsapp.net") ? to : to + "@s.whatsapp.net"
    let content

    if (image) {
      content = { image: { url: image }, caption: text || "" }
    } else if (gif) {
      content = { video: { url: gif }, caption: text || "", gifPlayback: true }
    } else if (file) {
      content = { document: { url: file }, caption: text || "" }
    } else if (text) {
      content = { text }
    } else {
      return res.status(400).send({ error: "Missing message content" })
    }

    await global.sock.sendMessage(jid, content)
    console.log(`✅ Sent to ${to}:`, content)
    res.send({ status: "sent", to, text })
  } catch (err) {
    console.error("❌ Send error:", err)
    res.status(500).send({ error: err.message })
  }
})

// Start server
app.listen(PORT, () => console.log(`🚀 API running on http://localhost:${PORT}`))

async function startSock() {
  const { version, isLatest } = await fetchLatestBaileysVersion()
  console.log(`🌀 WhatsApp version: ${version.join(".")} (latest: ${isLatest})`)

  const { state, saveCreds } = await useMultiFileAuthState("./auth")
  const sock = makeWASocket({
    version,
    logger: P({ level: "silent" }),
    auth: state,
    printQRInTerminal: false,
    browser: ["GuixSystem", "Firefox", "Linux"]
  })
  global.sock = sock

  sock.ev.on("creds.update", saveCreds)

  sock.ev.on("connection.update", (update) => {
    const { connection, lastDisconnect, qr } = update
    if (qr) {
      console.clear()
      console.log("📱 Scan this QR code:")
      qrcode.generate(qr, { small: true })
    }
    if (connection === "close") {
      const shouldReconnect =
        lastDisconnect?.error?.output?.statusCode !== DisconnectReason.loggedOut
      console.log("❌ Connection closed. Reconnecting:", shouldReconnect)
      if (shouldReconnect) startSock()
    } else if (connection === "open") {
      console.log("✅ Connected to WhatsApp!")
    }
  })

  sock.ev.on("messages.upsert", async ({ messages: msgs, type }) => {
    if (type !== "notify") return
    for (const msg of msgs) {
      const from = msg.key.remoteJid
      const text = msg.message?.conversation || msg.message?.extendedTextMessage?.text
      if (text) {
        const record = {
          from,
          text,
          timestamp: new Date().toISOString()
        }
        messages.push(record)
        console.log(`💬 ${from}: ${text}`)
        // keep file under 200 messages
        if (messages.length > 200) messages = messages.slice(-200)
      }
    }
  })
}

startSock()
