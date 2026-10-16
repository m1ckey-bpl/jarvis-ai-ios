"""Integrations: official APIs only, credentials encrypted at rest, honest errors."""

from __future__ import annotations

import json
import sqlite3

import pytest

from app.config import Settings
from app.errors import BadRequest, NotConfigured, ProviderUnavailable
from app.integrations import CredentialStore, IntegrationHub, SecretBox
from app.transport import RecordingTransport


def hub(**overrides) -> tuple[IntegrationHub, RecordingTransport, sqlite3.Connection]:
    connection = sqlite3.connect(":memory:")
    values = {"host": "127.0.0.1", "port": 0, "auth_token": "t" * 24}
    values.update(overrides)
    settings = Settings(**values)
    transport = RecordingTransport()
    credentials = CredentialStore(connection, SecretBox(settings.auth_token))
    return IntegrationHub(settings, transport, credentials), transport, connection


def test_secret_box_round_trip_and_integrity() -> None:
    box = SecretBox("key-material")
    token = box.encrypt("1//refresh-token-value")
    assert "refresh-token-value" not in token
    assert box.decrypt(token) == "1//refresh-token-value"

    tampered = token[:-4] + "AAAA"
    with pytest.raises(BadRequest):
        box.decrypt(tampered)


def test_credentials_are_encrypted_at_rest_and_listed_by_name_only() -> None:
    connection = sqlite3.connect(":memory:")
    store = CredentialStore(connection, SecretBox("k" * 20))
    store.set("google.refresh_token", "secret-refresh-value")
    assert store.get("google.refresh_token") == "secret-refresh-value"
    raw = connection.execute("SELECT value FROM credentials").fetchone()[0]
    assert "secret-refresh-value" not in raw
    assert store.names() == ["google.refresh_token"]
    store.delete("google.refresh_token")
    assert store.get("google.refresh_token") is None


def test_web_search_requires_a_key_and_uses_it_when_present() -> None:
    hub_without_key, _, _ = hub()
    with pytest.raises(NotConfigured) as error:
        hub_without_key.web_search("weather")
    assert "search API key" in error.value.message

    with_key, transport, _ = hub(search_api_key="search-key")
    transport.queue(200, {"web": {"results": [{"title": "Weather", "url": "https://example.com",
                                               "description": "Sunny"}]}})
    results = with_key.web_search("weather", limit=1)
    assert results[0]["title"] == "Weather"
    assert transport.requests[0].headers["X-Subscription-Token"] == "search-key"


def test_github_requires_a_token_and_validates_the_repository() -> None:
    without, _, _ = hub()
    with pytest.raises(NotConfigured):
        without.github_issues("owner/name")

    with_token, transport, _ = hub(github_token="ghp_example")
    with pytest.raises(BadRequest):
        with_token.github_issues("not-a-repository")
    transport.queue(200, [{"number": 7, "title": "Fix uploads", "html_url": "https://github.com/o/n/issues/7",
                           "state": "open"}])
    issues = with_token.github_issues("owner/name")
    assert issues[0]["number"] == 7
    assert transport.requests[-1].headers["Authorization"] == "Bearer ghp_example"


def test_whatsapp_explains_that_personal_chats_have_no_api() -> None:
    without, _, _ = hub()
    with pytest.raises(NotConfigured) as error:
        without.whatsapp_send("+911234567890", "hi")
    assert "personal" in error.value.message.lower()

    with_business, transport, _ = hub(whatsapp_token="wa-token", whatsapp_phone_number_id="555")
    with pytest.raises(BadRequest):
        with_business.whatsapp_send("911234567890", "hi")      # not E.164
    transport.queue(200, {"messages": [{"id": "wamid.ABC"}]})
    result = with_business.whatsapp_send("+911234567890", "hi")
    assert result["id"] == "wamid.ABC"
    body = json.loads(transport.requests[-1].body.decode("utf-8"))
    assert body["messaging_product"] == "whatsapp"
    assert body["to"] == "911234567890"


def test_whatsapp_failure_is_reported_with_the_provider_message() -> None:
    with_business, transport, _ = hub(whatsapp_token="wa-token", whatsapp_phone_number_id="555")
    transport.queue(400, {"error": {"message": "Recipient not in the allowed test list"}})
    with pytest.raises(ProviderUnavailable) as error:
        with_business.whatsapp_send("+911234567890", "hi")
    assert "allowed test list" in error.value.message


def test_instagram_requires_a_professional_account_token() -> None:
    without, _, _ = hub()
    with pytest.raises(NotConfigured) as error:
        without.instagram_profile()
    assert "professional" in error.value.message.lower()

    with_token, transport, _ = hub(instagram_token="IGQV-example")
    transport.queue(200, {"id": "17841400000", "username": "jarvis.demo", "account_type": "BUSINESS"})
    profile = with_token.instagram_profile()
    assert profile["username"] == "jarvis.demo"


def test_google_oauth_flow_uses_pkce_and_server_side_secret() -> None:
    application, transport, _ = hub(google_client_id="client-id",
                                    google_client_secret="the-secret",
                                    google_redirect_uri="https://backend.example/cb")
    start = application.google.start(["https://www.googleapis.com/auth/gmail.send"])
    assert "code_challenge=" in start["authorizationURL"]
    assert "client_id=client-id" in start["authorizationURL"]
    assert "the-secret" not in start["authorizationURL"]          # the secret never appears in the URL

    transport.queue(200, {"refresh_token": "1//r", "scope": "https://www.googleapis.com/auth/gmail.send"})
    result = application.google.callback("code-123", start["state"])
    assert result["scopes"] == ["https://www.googleapis.com/auth/gmail.send"]
    exchange = transport.requests[-1]
    assert b"client_secret=the-secret" in exchange.body
    assert b"code_verifier=" in exchange.body
    assert "1//r" not in exchange.url


def test_google_access_token_refresh_uses_stored_refresh_token() -> None:
    application, transport, _ = hub(google_client_id="client-id", google_client_secret="the-secret")
    application.credentials.set("google.refresh_token", "1//stored")
    transport.queue(200, {"access_token": "ya29.access"})
    assert application.google.access_token() == "ya29.access"
    assert b"grant_type=refresh_token" in transport.requests[-1].body


def test_google_refresh_failure_is_actionable() -> None:
    application, transport, _ = hub(google_client_id="client-id", google_client_secret="the-secret")
    application.credentials.set("google.refresh_token", "1//stale")
    transport.queue(400, {"error": "invalid_grant"})
    with pytest.raises(ProviderUnavailable) as error:
        application.google.access_token()
    assert "reconnect" in error.value.message


def test_gmail_send_builds_an_rfc822_message() -> None:
    application, transport, _ = hub(google_client_id="client-id", google_client_secret="the-secret")
    application.credentials.set("google.refresh_token", "1//stored")
    transport.queue(200, {"access_token": "ya29.access"})
    transport.queue(200, {"id": "msg-1", "threadId": "thread-1"})
    result = application.gmail_send("someone@example.com", "Hello", "Body text")
    assert result["id"] == "msg-1"
    payload = json.loads(transport.requests[-1].body.decode("utf-8"))
    import base64

    decoded = base64.urlsafe_b64decode(payload["raw"]).decode("utf-8")
    assert "To: someone@example.com" in decoded
    assert "Subject: Hello" in decoded
    assert "Body text" in decoded


def test_capability_report_never_includes_secret_values() -> None:
    application, _, _ = hub(github_token="ghp_secretsecretsecret", instagram_token="IGQV_secret_token",
                           whatsapp_token="wa-secret", whatsapp_phone_number_id="555",
                           search_api_key="search-secret", provider_api_key="gsk_secret")
    report = application.capability_report()
    text = json.dumps(report)
    for secret in ("ghp_secretsecretsecret", "IGQV_secret_token", "wa-secret", "search-secret", "gsk_secret"):
        assert secret not in text
    assert report["github"] == "configured"
    assert report["google_account_connected"] == "no"
