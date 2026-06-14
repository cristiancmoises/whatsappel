# 📱 WHATSAPP.EL - Emacs WhatsApp Integration

A local integration between **Emacs** and **WhatsApp Web**, powered by [Baileys](https://github.com/WhiskeySockets/Baileys) API.  
Send and receive WhatsApp messages directly from Emacs — no cloud services, no middlemen, fully local and secure.

---

## 🚀 Features

- ✅ Send WhatsApp messages from Emacs.
- 📥 Receive and log incoming messages in the Node.js console.
- 🖼️ Support for sending images, GIFs, and files (coming soon) - usage of .bak files)
- 🔒 Fully local communication using WhatsApp Web protocol.
- 🧠 Persistent session — no need to scan QR every time.
- 💻 Works on GNU/Linux, macOS, and Windows.

---

## ⚙️ Requirements

You’ll need:
- **Node.js ≥ 18**
- **npm** or **yarn**
- **Emacs ≥ 28**
- Internet access for WhatsApp Web linking

---

## 🧩 Installation

### 1️⃣ CAll you neeed to do:

     mkdir ~/whatsapp
     cd ~/whatsapp 
     npm init -y
     npm install express body-parser @whiskeysockets/baileys qrcode-terminal pino
     git clone https://codeberg.org/berkeley/batizado
     cd batizado
     cp server.js ~/whatsapp/
     cp whatsapp.el ~/.emacs.d/

## 2️⃣ Iun the server:: 

     cd ~/whatsapp 
     node server.js

You’ll see output similar to:

📱 Scan this QR code with WhatsApp (Linked Devices)
🚀 API running on http://localhost:3000

Now open WhatsApp on your phone → Linked Devices → Link a device → scan the QR code.

## 🧠 Emacs Setup 
Add into your emacs:
      (load "~/.emacs.d/whatsapp.el")

## 💬 Usage
▶️ Send a Message

 In Emacs, run:

      M-x whatsapp-send

Then enter:

Number (e.g., 5599999999999)
Message: Olá do Emacs!

If all is working, you’ll see:

✅ Message sent to 5599999999999

## 📥 Receiving Messages

All incoming messages appear in the Node.js console:

💬 New message from 5599999999999: Ae galêraah do Bastizzadôh!

Soon, these will also appear in Emacs buffers.

To check logs:

tail -f whatsapp.log

## 📜 License

This project is released under the GNU General Public License v3.0
See the LICENSE

file for details.

    Community contributors are welcome ❤️

🧩 Future Plans

   - Emacs buffer to view and reply to messages.

   - File, image, and GIF upload support.

   - Contact list and group message features.

   - Optional encryption and auto-backup.


> Enjoy messaging from the power of Emacs ⚡
