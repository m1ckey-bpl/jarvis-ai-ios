"""Server-side integrations, all through official APIs.

Nothing here imitates a feature that a provider does not expose. Where an action
is impossible through official channels, the method raises `NotConfigured` with an
explanation instead of pretending.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
import urllib.parse
from dataclasses import dataclass
from typing import Any

from .errors import BadRequest, NotConfigured, ProviderUnavailable
from .transport import HTTPRequest, Transport

GOOGLE_AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN = "https://oauth2.googleapis.com/token"
GMAIL_API = "https://gmail.googleapis.com/gmail/v1/users/me"
GRAPH = "https://graph.facebook.com/v21.0"
GITHUB_API = "https://api.github.com"


# --------------------------------------------------------------- secret box ----
class SecretBox:
    """Keystream encryption for values at rest in the SQLite file.

    Honest scope: this protects against casual inspection of a leaked database
    file — it is *not* a substitute for full-disk encryption, and the key lives in
    the process environment. Operators should enable platform disk encryption and
    keep `JARVIS_BACKEND_TOKEN` out of logs.
    """

    def __init__(self, key_material: str) -> None:
        if not key_material:
            raise ValueError("a non-empty key is required")
        self._key = hashlib.sha256(key_material.encode("utf-8")).digest()

    def _keystream(self, nonce: bytes, length: int) -> bytes:
        chunks = []
        counter = 0
        while sum(len(chunk) for chunk in chunks) < length:
            chunks.append(hmac.new(self._key, nonce + counter.to_bytes(4, "big"), hashlib.sha256).digest())
            counter += 1
        return b"".join(chunks)[:length]

    def encrypt(self, plaintext: str) -> str:
        nonce = os.urandom(16)
        data = plaintext.encode("utf-8")
        stream = self._keystream(nonce, len(data))
        ciphertext = bytes(a ^ b for a, b in zip(data, stream))
        tag = hmac.new(self._key, nonce + ciphertext, hashlib.sha256).digest()[:16]
        return base64.urlsafe_b64encode(nonce + tag + ciphertext).decode("ascii")

    def decrypt(self, token: str) -> str:
        raw = base64.urlsafe_b64decode(token.encode("ascii"))
        nonce, tag, ciphertext = raw[:16], raw[16:32], raw[32:]
        expected = hmac.new(self._key, nonce + ciphertext, hashlib.sha256).digest()[:16]
        if not hmac.compare_digest(tag, expected):
            raise BadRequest("the stored credential failed its integrity check")
        stream = self._keystream(nonce, len(ciphertext))
        return bytes(a ^ b for a, b in zip(ciphertext, stream)).decode("utf-8")


# ------------------------------------------------------------------ storage ----
CREDENTIAL_SCHEMA = """
CREATE TABLE IF NOT EXISTS credentials (
    name TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at REAL NOT NULL
);
"""


class CredentialStore:
    def __init__(self, connection: sqlite3.Connection, box: SecretBox) -> None:
        self.connection = connection
        self.box = box
        self.connection.executescript(CREDENTIAL_SCHEMA)
        self.connection.commit()

    def set(self, name: str, value: str) -> None:
        self.connection.execute(
            "INSERT INTO credentials (name, value, updated_at) VALUES (?,?,?) "
            "ON CONFLICT(name) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
            (name, self.box.encrypt(value), time.time()))
        self.connection.commit()

    def get(self, name: str) -> str | None:
        row = self.connection.execute("SELECT value FROM credentials WHERE name = ?", (name,)).fetchone()
        return self.box.decrypt(row[0]) if row else None

    def delete(self, name: str) -> None:
        self.connection.execute("DELETE FROM credentials WHERE name = ?", (name,))
        self.connection.commit()

    def names(self) -> list[str]:
        return [row[0] for row in self.connection.execute("SELECT name FROM credentials ORDER BY name")]


# -------------------------------------------------------------- google oauth ---
@dataclass
class PKCEChallenge:
    verifier: str
    challenge: str
    state: str
    created_at: float

    @classmethod
    def generate(cls) -> "PKCEChallenge":
        verifier = base64.urlsafe_b64encode(os.urandom(48)).decode("ascii").rstrip("=")
        digest = hashlib.sha256(verifier.encode("ascii")).digest()
        challenge = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
        return cls(verifier=verifier, challenge=challenge, state=secrets.token_urlsafe(24), created_at=time.time())


class GoogleOAuth:
    """Authorization-code flow with PKCE.

    The point of doing this on the server: the **client secret** never ships in the
    iOS app, and the refresh token never leaves the server.
    """

    def __init__(self, settings: Any, transport: Transport, credentials: CredentialStore) -> None:
        self.settings = settings
        self.transport = transport
        self.credentials = credentials
        self._pending: dict[str, PKCEChallenge] = {}

    @property
    def configured(self) -> bool:
        return bool(self.settings.google_client_id and self.settings.google_client_secret)

    def start(self, scopes: list[str] | None = None) -> dict[str, Any]:
        if not self.configured:
            raise NotConfigured(
                "Google OAuth is not configured on this server: set JARVIS_GOOGLE_CLIENT_ID "
                "and JARVIS_GOOGLE_CLIENT_SECRET (a free Google Cloud project is enough)."
            )
        challenge = PKCEChallenge.generate()
        self._pending[challenge.state] = challenge
        scope = " ".join(scopes or ["https://www.googleapis.com/auth/gmail.readonly"])
        query = urllib.parse.urlencode({
            "client_id": self.settings.google_client_id,
            "response_type": "code",
            "redirect_uri": self.settings.google_redirect_uri,
            "scope": scope,
            "code_challenge": challenge.challenge,
            "code_challenge_method": "S256",
            "access_type": "offline",
            "prompt": "consent",
            "state": challenge.state,
        })
        return {"authorizationURL": f"{GOOGLE_AUTH}?{query}", "state": challenge.state, "scopes": scope.split()}

    def callback(self, code: str, state: str) -> dict[str, Any]:
        if not self.configured:
            raise NotConfigured("Google OAuth is not configured on this server.")
        challenge = self._pending.pop(state, None)
        if challenge is None:
            raise BadRequest("the OAuth state is unknown or has already been used")
        if time.time() - challenge.created_at > 600:
            raise BadRequest("the OAuth state expired; start the flow again")
        body = urllib.parse.urlencode({
            "client_id": self.settings.google_client_id,
            "client_secret": self.settings.google_client_secret,
            "code": code,
            "code_verifier": challenge.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": self.settings.google_redirect_uri,
        }).encode("utf-8")
        response = self.transport.send(HTTPRequest(
            url=GOOGLE_TOKEN, method="POST", label="google.token",
            headers={"Content-Type": "application/x-www-form-urlencoded"}, body=body))
        payload = response.json()
        if response.status >= 400 or "refresh_token" not in payload:
            raise ProviderUnavailable(f"Google rejected the code exchange: {payload.get('error', response.status)}")
        self.credentials.set("google.refresh_token", payload["refresh_token"])
        return {"scopes": str(payload.get("scope", "")).split(), "expiresIn": payload.get("expires_in")}

    def access_token(self) -> str:
        refresh = self.credentials.get("google.refresh_token")
        if not refresh:
            raise NotConfigured("no Google account is connected to this server yet")
        body = urllib.parse.urlencode({
            "client_id": self.settings.google_client_id,
            "client_secret": self.settings.google_client_secret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        }).encode("utf-8")
        response = self.transport.send(HTTPRequest(
            url=GOOGLE_TOKEN, method="POST", label="google.refresh",
            headers={"Content-Type": "application/x-www-form-urlencoded"}, body=body))
        payload = response.json()
        if response.status >= 400 or "access_token" not in payload:
            raise ProviderUnavailable("Google refused to refresh the access token; reconnect the account")
        return payload["access_token"]


# ------------------------------------------------------------------ hub --------
class IntegrationHub:
    def __init__(self, settings: Any, transport: Transport, credentials: CredentialStore) -> None:
        self.settings = settings
        self.transport = transport
        self.credentials = credentials
        self.google = GoogleOAuth(settings, transport, credentials)

    # -- web search --------------------------------------------------------
    def web_search(self, query: str, *, limit: int = 5) -> list[dict[str, Any]]:
        if not self.settings.search_api_key:
            raise NotConfigured(
                "web search needs a free search API key (for example Brave Search's free "
                "tier). Set JARVIS_SEARCH_API_KEY on the server, or use the device's "
                "own key in the app."
            )
        url = "https://api.search.brave.com/res/v1/web/search?" + urllib.parse.urlencode({"q": query, "count": limit})
        response = self.transport.send(HTTPRequest(url=url, label="search.web",
                                                   headers={"Accept": "application/json",
                                                            "X-Subscription-Token": self.settings.search_api_key}))
        if response.status >= 400:
            raise ProviderUnavailable(f"the search provider returned HTTP {response.status}")
        payload = response.json()
        results = []
        for item in (payload.get("web", {}) or {}).get("results", [])[:limit]:
            results.append({"title": item.get("title"), "url": item.get("url"),
                            "description": item.get("description")})
        return results

    # -- github ------------------------------------------------------------
    def github_issues(self, repository: str, *, state: str = "open") -> list[dict[str, Any]]:
        if not self.settings.github_token:
            raise NotConfigured("GitHub is not connected to this server (set JARVIS_GITHUB_TOKEN).")
        if "/" not in repository:
            raise BadRequest("repository must be 'owner/name'")
        url = f"{GITHUB_API}/repos/{repository}/issues?" + urllib.parse.urlencode({"state": state, "per_page": 20})
        response = self.transport.send(HTTPRequest(url=url, label="github.issues", headers=self._github_headers()))
        if response.status >= 400:
            raise ProviderUnavailable(f"GitHub returned HTTP {response.status}")
        return [{"number": item.get("number"), "title": item.get("title"), "url": item.get("html_url"),
                 "state": item.get("state")} for item in response.json() if isinstance(item, dict)]

    def _github_headers(self) -> dict[str, str]:
        return {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
                "Authorization": f"Bearer {self.settings.github_token}"}

    # -- gmail -------------------------------------------------------------
    def gmail_send(self, to: str, subject: str, body: str) -> dict[str, Any]:
        token = self.google.access_token()
        message = f"To: {to}\r\nSubject: {subject}\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\n\r\n{body}"
        encoded = base64.urlsafe_b64encode(message.encode("utf-8")).decode("ascii")
        response = self.transport.send(HTTPRequest(
            url=f"{GMAIL_API}/messages/send", method="POST", label="gmail.send",
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            body=json.dumps({"raw": encoded}).encode("utf-8")))
        payload = response.json()
        if response.status >= 400:
            raise ProviderUnavailable(f"Gmail refused the message: {payload.get('error', {}).get('message', response.status)}")
        return {"id": payload.get("id"), "threadId": payload.get("threadId")}

    def gmail_search(self, query: str, *, limit: int = 10) -> list[dict[str, Any]]:
        token = self.google.access_token()
        url = f"{GMAIL_API}/messages?" + urllib.parse.urlencode({"q": query, "maxResults": limit})
        response = self.transport.send(HTTPRequest(url=url, label="gmail.search",
                                                   headers={"Authorization": f"Bearer {token}"}))
        if response.status >= 400:
            raise ProviderUnavailable(f"Gmail returned HTTP {response.status}")
        return [{"id": item.get("id"), "threadId": item.get("threadId")}
                for item in response.json().get("messages", [])]

    # -- whatsapp business platform ---------------------------------------
    def whatsapp_send(self, to: str, text: str) -> dict[str, Any]:
        if not (self.settings.whatsapp_token and self.settings.whatsapp_phone_number_id):
            raise NotConfigured(
                "WhatsApp Business Platform credentials are not configured. Personal WhatsApp "
                "accounts have no official messaging API — the app therefore composes messages "
                "for you to send, and only this Business API path can send server-side."
            )
        if not to.startswith("+"):
            raise BadRequest("the recipient must be an E.164 phone number, e.g. +911234567890")
        url = f"{GRAPH}/{self.settings.whatsapp_phone_number_id}/messages"
        payload = {"messaging_product": "whatsapp", "recipient_type": "individual",
                   "to": to.lstrip("+"), "type": "text", "text": {"preview_url": False, "body": text}}
        response = self.transport.send(HTTPRequest(
            url=url, method="POST", label="whatsapp.send",
            headers={"Authorization": f"Bearer {self.settings.whatsapp_token}",
                     "Content-Type": "application/json"},
            body=json.dumps(payload).encode("utf-8")))
        body = response.json()
        if response.status >= 400:
            raise ProviderUnavailable(f"WhatsApp refused the message: {body.get('error', {}).get('message', response.status)}")
        messages = body.get("messages", [{}])
        return {"id": messages[0].get("id"), "status": "accepted"}

    # -- instagram graph (professional accounts only) ----------------------
    def instagram_profile(self) -> dict[str, Any]:
        if not self.settings.instagram_token:
            raise NotConfigured(
                "Instagram Graph access is not configured. Only professional (business/creator) "
                "accounts have an official API; personal accounts have none, and JARVIS will not "
                "use an unofficial one."
            )
        url = f"{GRAPH}/me?" + urllib.parse.urlencode({
            "fields": "id,username,account_type,media_count", "access_token": self.settings.instagram_token})
        response = self.transport.send(HTTPRequest(url=url, label="instagram.profile"))
        payload = response.json()
        if response.status >= 400:
            raise ProviderUnavailable(f"Instagram returned HTTP {response.status}")
        return payload

    def capability_report(self) -> dict[str, str]:
        report = dict(self.settings.capability_report())
        report["google_account_connected"] = "yes" if self.credentials.get("google.refresh_token") else "no"
        return report
