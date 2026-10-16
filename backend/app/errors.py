"""Error taxonomy shared by the API layer.

Mirrors the iOS `JarvisError` taxonomy so that a client can present the same
recovery affordances regardless of where the failure happened.
"""

from __future__ import annotations


class JarvisBackendError(Exception):
    status = 500
    code = "internal_error"

    def __init__(self, message: str, *, details: dict | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.details = details or {}

    def payload(self) -> dict:
        body = {"error": {"code": self.code, "message": self.message}}
        if self.details:
            body["error"]["details"] = self.details
        return body


class BadRequest(JarvisBackendError):
    status, code = 400, "invalid_arguments"


class Unauthorized(JarvisBackendError):
    status, code = 401, "unauthorized"


class Forbidden(JarvisBackendError):
    status, code = 403, "forbidden"


class NotFound(JarvisBackendError):
    status, code = 404, "not_found"


class PolicyBlocked(Forbidden):
    """A request the server refuses for policy reasons (a 403 with its own code)."""

    status, code = 403, "policy_blocked"


class ConfirmationRequired(JarvisBackendError):
    status, code = 409, "confirmation_required"


class RateLimited(JarvisBackendError):
    status, code = 429, "rate_limited"


class ProviderUnavailable(JarvisBackendError):
    status, code = 502, "provider_unavailable"


class NotConfigured(JarvisBackendError):
    status, code = 503, "not_configured"
