"""
bunq sandbox wrapper — the only module in the codebase that talks to bunq.

Public API:
    request_payment(amount_cents, currency, payer_email, description) -> dict
    make_payment(amount_cents, currency, recipient_email, description) -> dict
    get_request_status(request_id) -> dict
    register_webhook(callback_url) -> None

Notes:
- Holds a singleton BunqClient. The 3-step authenticate() handshake hits a
  session-server endpoint rate-limited to 1/30s, so we do it once per process.
- Amounts are cents internally; converted to bunq's "X.XX" string only at the
  HTTP boundary. Never let float touch currency.
"""

import sys
from pathlib import Path
from threading import Lock

# /bunq sits at the repo root and is not a pip package — add it to sys.path once
_BUNQ_DIR = Path(__file__).resolve().parents[3] / "bunq"
if str(_BUNQ_DIR) not in sys.path:
    sys.path.insert(0, str(_BUNQ_DIR))

from bunq_client import BunqClient  # noqa: E402

from app.config import settings  # noqa: E402

_client: BunqClient | None = None
_account_id: int | None = None
_lock = Lock()


def _get_client() -> tuple[BunqClient, int]:
    """Return the authenticated singleton client + cached primary account id."""
    global _client, _account_id
    with _lock:
        if _client is None:
            if not settings.bunq_api_key:
                raise RuntimeError(
                    "BUNQ_API_KEY is not set — add it to agent/.env to use payment routes."
                )
            c = BunqClient(api_key=settings.bunq_api_key, sandbox=settings.bunq_use_sandbox)
            c.authenticate()
            _client = c
            _account_id = c.get_primary_account_id()
        assert _client is not None and _account_id is not None
        return _client, _account_id


def _fmt(amount_cents: int) -> str:
    if amount_cents < 0:
        raise ValueError("amount_cents must be >= 0")
    return f"{amount_cents // 100}.{amount_cents % 100:02d}"


def request_payment(
    amount_cents: int,
    currency: str,
    payer_email: str,
    description: str,
) -> dict:
    """
    Create a RequestInquiry asking `payer_email` to pay us. Returns
    {"request_id": int, "status": "PENDING"}.
    """
    c, acc = _get_client()
    resp = c.post(
        f"user/{c.user_id}/monetary-account/{acc}/request-inquiry",
        {
            "amount_inquired": {"value": _fmt(amount_cents), "currency": currency},
            "counterparty_alias": {
                "type": "EMAIL",
                "value": payer_email,
                "name": payer_email,
            },
            "description": description,
            "allow_bunqme": False,
        },
    )
    return {"request_id": resp[0]["Id"]["id"], "status": "PENDING"}


def make_payment(
    amount_cents: int,
    currency: str,
    recipient_email: str,
    description: str,
) -> dict:
    """Direct Payment — no approval step. Returns {"payment_id": int}."""
    c, acc = _get_client()
    resp = c.post(
        f"user/{c.user_id}/monetary-account/{acc}/payment",
        {
            "amount": {"value": _fmt(amount_cents), "currency": currency},
            "counterparty_alias": {
                "type": "EMAIL",
                "value": recipient_email,
                "name": recipient_email,
            },
            "description": description,
        },
    )
    return {"payment_id": resp[0]["Id"]["id"]}


def get_request_status(request_id: int) -> dict:
    """Poll a RequestInquiry. Status: PENDING|ACCEPTED|REJECTED|REVOKED|EXPIRED."""
    c, acc = _get_client()
    resp = c.get(
        f"user/{c.user_id}/monetary-account/{acc}/request-inquiry/{request_id}"
    )
    r = resp[0]["RequestInquiry"]
    return {
        "status": r["status"],
        "amount": r["amount_inquired"]["value"],
        "currency": r["amount_inquired"]["currency"],
    }


def register_webhook(callback_url: str) -> None:
    """Register PAYMENT + MUTATION callbacks at `callback_url`."""
    c, _ = _get_client()
    c.post(
        f"user/{c.user_id}/notification-filter-url",
        {
            "notification_filters": [
                {"category": "PAYMENT", "notification_target": callback_url},
                {"category": "MUTATION", "notification_target": callback_url},
            ],
        },
    )
