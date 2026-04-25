"""Provision a fresh bunq sandbox account for a Supabase customer.

provision_for(user_id) is idempotent — returns the existing row if the
customer already has a bunq account, otherwise:

  1. POST /sandbox-user-person → fresh API key
  2. 3-step auth (installation, device-server, session-server) using the
     CustomerBunqClient subclass, which captures the auto-assigned email
     alias from the session response.
  3. GET monetary-account-bank → primary account id
  4. Top up the new account: send a RequestInquiry FROM this user TO
     sugardaddy@bunq.com (sugardaddy auto-pays) so the customer has
     balance to spend on their first order.
  5. Persist everything to customer_bunq_accounts via _save_context().

Run in a background task on /session — provisioning is slow (hits the
1-req-per-30s session-server limit if multiple users sign up at once)
and we don't want to block /session on it.
"""
from __future__ import annotations

import logging
import sys
from pathlib import Path

# Same sys.path trick as EchoPayBunqClient — make the vendored toolkit
# importable regardless of CWD. Repo root = three levels above this file's
# parent package.
REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bunq.bunq_client import BunqClient  # type: ignore[import]

from app.bunq.customer_client import CustomerBunqClient
from app.db.supabase import get_sb

log = logging.getLogger(__name__)

# Default top-up amount — gives the customer enough sandbox balance for the
# demo. Sugardaddy caps individual requests at EUR 500.
TOPUP_AMOUNT_EUR = 250.0


def has_account(supabase_user_id: str) -> bool:
    sb = get_sb()
    res = (
        sb.table("customer_bunq_accounts")
        .select("user_id")
        .eq("user_id", supabase_user_id)
        .maybe_single()
        .execute()
    )
    return res is not None and bool(res.data)


def provision_for(supabase_user_id: str) -> dict:
    """Create or fetch the customer's bunq sandbox account. Idempotent.

    Returns the customer_bunq_accounts row dict.
    """
    sb = get_sb()

    # Idempotency check
    existing = (
        sb.table("customer_bunq_accounts")
        .select("*")
        .eq("user_id", supabase_user_id)
        .maybe_single()
        .execute()
    )
    if existing is not None and existing.data:
        log.info(
            "provision_for: user_id=%s already has bunq account email=%s",
            supabase_user_id, existing.data.get("bunq_email"),
        )
        return existing.data

    log.info("provision_for: creating fresh sandbox user for user_id=%s",
             supabase_user_id)

    # 1. New sandbox user → API key
    api_key = BunqClient.create_sandbox_user()

    # 2. 3-step auth + alias capture
    client = CustomerBunqClient(
        supabase_user_id=supabase_user_id, api_key=api_key, sandbox=True,
    )
    client._step1_installation()
    client._step2_device_server()
    client._step3_session_server()

    if not client.bunq_email:
        raise RuntimeError(
            "provision_for: session-server response had no EMAIL alias "
            f"for user_id={supabase_user_id}"
        )

    # 3. Primary account
    client.discover_primary_account()

    # 4. Top up via sugardaddy. The customer's account has zero balance after
    # creation; sending a request TO sugardaddy auto-pays and credits us.
    try:
        body = {
            "amount_inquired": {
                "value": f"{TOPUP_AMOUNT_EUR:.2f}",
                "currency": "EUR",
            },
            "counterparty_alias": {
                "type": "EMAIL",
                "value": "sugardaddy@bunq.com",
                "name": "Sugar Daddy",
            },
            "description": f"EchoPay top-up for user {supabase_user_id}",
            "allow_bunqme": False,
        }
        client.post(
            f"user/{client.user_id}/monetary-account/"
            f"{client.bunq_account_id}/request-inquiry",
            body,
        )
        log.info("provision_for: topped up user_id=%s with EUR %.2f",
                 supabase_user_id, TOPUP_AMOUNT_EUR)
    except Exception as e:
        # Top-up failure is recoverable — customer can still receive requests,
        # they just won't be able to accept them until they have balance.
        # Log loudly so we notice during demo prep.
        log.error(
            "provision_for: top-up FAILED for user_id=%s: %r — customer "
            "won't be able to accept requests until balance is added",
            supabase_user_id, e,
        )

    # 5. Persist
    client._save_context()
    return client._row_dict()