"""Provision a fresh bunq sandbox account for an EchoPay customer.

provision_for(user_id) is idempotent — returns the existing row if the
customer already has a bunq account, otherwise:

  1. POST /sandbox-user-person → fresh API key
  2. 3-step auth (installation, device-server, session-server) via BunqClient
  3. GET monetary-account-bank → primary account id
  4. Top up the new account: send a RequestInquiry TO sugardaddy@bunq.com
     (sugardaddy auto-pays) so the customer starts with demo balance.
  5. Persist api_key + bunq_user_id + account_id to customer_bunq_accounts.

Call provision_for from a FastAPI async route via asyncio.to_thread — the
bunq 3-step auth uses synchronous HTTP and must not block the event loop.

Rate-limit note: bunq sandbox caps session-server at 1 req/30 s per device.
If multiple users sign up simultaneously, provision_for calls will serialise
on the bunq side. Accept this for the demo; use a queue in production.
"""

from __future__ import annotations

import asyncio
import logging
import sys
from pathlib import Path
from typing import Any

from fastapi import HTTPException

from app.services import supabase_context

# The bunq toolkit lives at repo-root/bunq/ (same sys.path trick as bunq_service.py)
_BUNQ_DIR = Path(__file__).resolve().parents[3] / "bunq"
if str(_BUNQ_DIR) not in sys.path:
    sys.path.insert(0, str(_BUNQ_DIR))

try:
    from bunq_client import BunqClient  # type: ignore[import-not-found]
except ModuleNotFoundError:
    BunqClient = None  # type: ignore[assignment]

log = logging.getLogger(__name__)

# Top-up amount — gives the customer enough sandbox balance for the demo.
# bunq's sugardaddy caps individual requests at EUR 500.
TOPUP_AMOUNT_EUR = 250.0


async def has_bunq_account(user_id: str) -> bool:
    """Return True if customer_bunq_accounts already has a row for this user."""
    row = await supabase_context._maybe_single(
        "customer_bunq_accounts", {"user_id": f"eq.{user_id}"}
    )
    return row is not None


async def provision_for(user_id: str) -> dict[str, Any]:
    """Create or fetch the customer's bunq sandbox account. Idempotent.

    Returns the customer_bunq_accounts row dict.
    """
    existing = await supabase_context._maybe_single(
        "customer_bunq_accounts", {"user_id": f"eq.{user_id}"}
    )
    if existing:
        log.info(
            "provision_for: user_id=%s already provisioned bunq_user=%s",
            user_id, existing.get("bunq_user_id"),
        )
        return existing

    if BunqClient is None:
        raise HTTPException(
            status_code=503,
            detail="bunq_client toolkit is not available on this server.",
        )

    # Synchronous bunq work — run in thread pool so the event loop stays free
    try:
        row = await asyncio.to_thread(_provision_sync, user_id)
    except Exception as exc:
        log.exception("provision_for: sandbox provisioning failed for user_id=%s", user_id)
        raise HTTPException(status_code=502, detail=f"bunq provisioning failed: {exc}") from exc

    await _upsert_account(row)
    log.info(
        "provision_for: saved user_id=%s bunq_user=%s account=%s",
        user_id, row.get("bunq_user_id"), row.get("bunq_account_id"),
    )
    return row


def _provision_sync(user_id: str) -> dict[str, Any]:
    """Synchronous bunq provisioning — called from asyncio.to_thread."""
    # 1. Fresh sandbox user → API key
    api_key: str = BunqClient.create_sandbox_user()
    log.info("_provision_sync: got api_key for user_id=%s", user_id)

    # 2. 3-step auth: installation → device-server → session-server
    client = BunqClient(api_key=api_key, sandbox=True)
    client.authenticate()

    # 3. Primary monetary account
    account_id: int = client.get_primary_account_id()

    # 4. Top up via sugardaddy so the customer has balance for demo orders
    try:
        client.post(
            f"user/{client.user_id}/monetary-account/{account_id}/request-inquiry",
            {
                "amount_inquired": {
                    "value": f"{TOPUP_AMOUNT_EUR:.2f}",
                    "currency": "EUR",
                },
                "counterparty_alias": {
                    "type": "EMAIL",
                    "value": "sugardaddy@bunq.com",
                    "name": "Sugar Daddy",
                },
                "description": f"EchoPay top-up for user {user_id}",
                "allow_bunqme": False,
            },
        )
        log.info(
            "_provision_sync: topped up user_id=%s EUR %.2f",
            user_id, TOPUP_AMOUNT_EUR,
        )
    except Exception as exc:
        # Top-up failure is recoverable — customer can still pay, they just
        # start with zero balance and the first payment will fail.
        log.error(
            "_provision_sync: top-up FAILED for user_id=%s: %r — customer "
            "will have zero sandbox balance until topped up",
            user_id, exc,
        )

    return {
        "user_id": user_id,
        "bunq_api_key": api_key,
        "bunq_user_id": str(client.user_id),
        "bunq_account_id": account_id,
    }


async def _upsert_account(row: dict[str, Any]) -> None:
    """Persist the customer's bunq account row to Supabase (upsert on user_id)."""
    await supabase_context._request(
        "POST",
        "customer_bunq_accounts",
        params={"on_conflict": "user_id"},
        json_body=row,
        extra_headers={"Prefer": "resolution=merge-duplicates,return=minimal"},
    )
