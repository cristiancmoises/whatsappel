// mediaretry_wapatch.go — whatsappel add-on: media retry for expired media.
//
// WhatsApp's media CDN URLs expire (history-synced media often 404/403s on
// download). whatsmeow can ask the sender's phone to re-upload via
// SendMediaRetryReceipt; the phone answers asynchronously with an events.MediaRetry
// that we decrypt to a fresh directPath. This file adds:
//
//   - POST /chat/mediaretry {"Id": "<message id>"}  — request a re-upload.
//   - handleMediaRetryEvent(...)                     — on the async response,
//     decrypt and rewrite the stored message's directPath so a later download
//     succeeds (wired with one line in wmiau.go's events.MediaRetry case).
//
// Best-effort: it only works if the sender is online and still has the media.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// mediaSubKeys are the media sub-message keys in a serialized waE2E.Message.
var mediaSubKeys = []string{
	"imageMessage", "videoMessage", "audioMessage", "documentMessage", "stickerMessage",
}

// lookupMediaKey parses the stored data_json for (userID, messageID) and returns
// the media key bytes plus the chat/sender JIDs and IsFromMe flag.
func (s *server) lookupMediaKey(userID, messageID string) (mk []byte, chatJID, senderJID string, fromMe bool, err error) {
	var datajson string
	row := s.db.QueryRow(s.db.Rebind(
		"SELECT datajson, chat_jid, sender_jid FROM message_history WHERE user_id=? AND message_id=? LIMIT 1"),
		userID, messageID)
	if err = row.Scan(&datajson, &chatJID, &senderJID); err != nil {
		return
	}
	var dj struct {
		Info    struct{ IsFromMe bool } `json:"Info"`
		Message map[string]json.RawMessage `json:"Message"`
	}
	if err = json.Unmarshal([]byte(datajson), &dj); err != nil {
		return
	}
	fromMe = dj.Info.IsFromMe
	for _, k := range mediaSubKeys {
		raw, ok := dj.Message[k]
		if !ok {
			continue
		}
		var mm struct {
			MediaKey string `json:"mediaKey"`
		}
		if json.Unmarshal(raw, &mm) == nil && mm.MediaKey != "" {
			mk, err = base64.StdEncoding.DecodeString(mm.MediaKey)
			return
		}
	}
	err = errors.New("no media key found in message")
	return
}

// MediaRetryRequest handles POST /chat/mediaretry — asks the sender to re-upload
// the media of an (expired) message identified by Id.
func (s *server) MediaRetryRequest() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		txtid := r.Context().Value("userinfo").(Values).Get("Id")
		cli := clientManager.GetWhatsmeowClient(txtid)
		if cli == nil {
			s.Respond(w, r, http.StatusInternalServerError, errors.New("no active whatsapp session"))
			return
		}
		var t struct{ Id string }
		if err := json.NewDecoder(r.Body).Decode(&t); err != nil || t.Id == "" {
			s.Respond(w, r, http.StatusBadRequest, errors.New("missing Id in payload"))
			return
		}
		mk, chatJID, senderJID, fromMe, err := s.lookupMediaKey(txtid, t.Id)
		if err != nil {
			s.Respond(w, r, http.StatusBadRequest, err)
			return
		}
		chat, _ := parseJID(chatJID)
		sender, _ := parseJID(senderJID)
		info := &types.MessageInfo{
			ID: t.Id,
			MessageSource: types.MessageSource{Chat: chat, Sender: sender, IsFromMe: fromMe},
		}
		if err := cli.SendMediaRetryReceipt(context.Background(), info, mk); err != nil {
			s.Respond(w, r, http.StatusInternalServerError, err)
			return
		}
		out, _ := json.Marshal(map[string]interface{}{"requested": true, "id": t.Id})
		s.Respond(w, r, http.StatusOK, string(out))
	}
}

// handleMediaRetryEvent decrypts an async MediaRetry response and rewrites the
// stored message's directPath (clearing the dead URL) so the next download works.
func (s *server) handleMediaRetryEvent(userID string, evt *events.MediaRetry) {
	mk, _, _, _, err := s.lookupMediaKey(userID, evt.MessageID)
	if err != nil || len(mk) == 0 {
		return
	}
	nm, err := whatsmeow.DecryptMediaRetryNotification(evt, mk)
	if err != nil {
		return
	}
	dp := nm.GetDirectPath()
	if dp == "" {
		return
	}
	var datajson string
	row := s.db.QueryRow(s.db.Rebind(
		"SELECT datajson FROM message_history WHERE user_id=? AND message_id=? LIMIT 1"),
		userID, evt.MessageID)
	if row.Scan(&datajson) != nil {
		return
	}
	var obj map[string]interface{}
	if json.Unmarshal([]byte(datajson), &obj) != nil {
		return
	}
	msg, _ := obj["Message"].(map[string]interface{})
	if msg == nil {
		return
	}
	for _, k := range mediaSubKeys {
		if sub, ok := msg[k].(map[string]interface{}); ok {
			sub["directPath"] = dp
			sub["URL"] = ""
			msg[k] = sub
			break
		}
	}
	obj["Message"] = msg
	updated, err := json.Marshal(obj)
	if err != nil {
		return
	}
	_, _ = s.db.Exec(s.db.Rebind(
		"UPDATE message_history SET datajson=? WHERE user_id=? AND message_id=?"),
		string(updated), userID, evt.MessageID)
}
