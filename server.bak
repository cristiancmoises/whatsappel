import express from "express"
import bodyParser from "body-parser"
import makeWASocket, {
  useMultiFileAuthState,
  DisconnectReason,
  fetchLatestBaileysVersion
} from "@whiskeysockets/baileys"
import qrcode from "qrcode-terminal"
import P from "pino"

const app = express()
const PORT = 3000

app.use(bodyParser.json())

app.get("/", (req, res) => res.send("✅ WhatsApp API running"))

app.post("/send", async (req, res) => {
  const { to, text } = req.body
  if (!to || !text) {
    return res.status(400).send({ error: "Missing 'to' or 'text'" })
  }

  try {
    if (!global.sock) return res.status(500).send({ error: "WhatsApp not connected" })
    await global.sock.sendMessage(to + "@s.whatsapp.net", { text })
    console.log(`✅ Message sent to ${to}: ${text}`)
    res.send({ status: "sent", to, text })
  } catch (err) {
    console.error("❌ Send error:", err)
    res.status(500).send({ error: err.message })
  }
})

app.listen(PORT, () => console.log(`🚀 API running on http://localhost:${PORT}`))

async function startSock() {
  const { version, isLatest } = await fetchLatestBaileysVersion()
  console.log(`🌀 Using WhatsApp version: ${version.join(".")} (latest: ${isLatest})`)
  const { state, saveCreds } = await useMultiFileAuthState("./auth")

  const sock = makeWASocket({
    version,
    logger: P({ level: "silent" }),
    auth: state,
    browser: ["GuixSystem", "Firefox", "Linux"]
  })

  global.sock = sock

  sock.ev.on("creds.update", saveCreds)

  sock.ev.on("connection.update", (update) => {
    const { connection, lastDisconnect, qr } = update

    if (qr) {
      console.clear()
      console.log("📱 Scan this QR code with WhatsApp (Linked Devices):")
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
}

startSock()
