"""Per-customer bunq sandbox client.

Subclasses BunqClient to:
  - Persist session state to Supabase (customer_bunq_accounts row keyed by
    Supabase user_id) instead of the toolkit's single bunq_context.json file.
  - Capture the auto-assigned email alias from the session-server response
    (the vendored client discards it). We need this alias as the recipient
    when the restaurant POSTs a RequestInquiry to the customer.

Why this exists separately from EchoPayBunqClient: that one represents the
RESTAURANT's bunq account (single, long-lived, per-process). This one
represents a CUSTOMER, instantiated per-request from a DB row.
"""
from __future__ import annotations

import logging
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization

# Reuse the same path-injection trick as EchoPayBunqClient so the vendored
# toolkit imports work regardless of CWD.
REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bunq.bunq_client import BunqClient  # type: ignore[import]

from app.db.supabase import get_sb

log = logging.getLogger(__name__)


class CustomerBunqClient(BunqClient):
    """Per-customer bunq sandbox client backed by customer_bunq_accounts.

    Construction modes:
      1. Fresh: pass api_key only. authenticate() runs the 3-step flow,
         _save_context() inserts/updates the row.
      2. Cached: pass user_id (and api_key). authenticate() loads the row
         via _load_context() and skips the 3-step flow if the session
         still works.

    The auto-assigned email alias is captured during _step3_session_server
    and persisted on the row as bunq_email — used by place_order as the
    counterparty alias.
    """

    def __init__(self, *, supabase_user_id: str, api_key: str | None = None,
                 sandbox: bool = True):
        # We may not know the api_key yet if we're loading from DB — pull it
        # from the row first when present, otherwise pass through.
        self.supabase_user_id = supabase_user_id
        self.bunq_email: str | None = None
        self.bunq_account_id: int | None = None

        if api_key is None:
            row = self._load_row()
            if row is None:
                raise ValueError(
                    f"CustomerBunqClient: no api_key passed and no row for "
                    f"user_id={supabase_user_id}"
                )
            api_key = row["bunq_api_key"]

        super().__init__(api_key=api_key, sandbox=sandbox)

    # ------------------------------------------------------------------
    # Session-server: capture the email alias
    # ------------------------------------------------------------------

    def _step3_session_server(self) -> None:
        # Borrow parent's behaviour but also stash UserPerson.alias.
        body = {"secret": self.api_key}
        resp = self._raw_post(
            "session-server", body, auth_token=self.installation_token
        )
        for item in resp:
            if "Token" in item:
                self.session_token = item["Token"]["token"]
            for key in ("UserPerson", "UserCompany", "UserApiKey"):
                if key in item:
                    user_obj = item[key]
                    self.user_id = user_obj["id"]
                    self.bunq_email = self._extract_email_alias(
                        user_obj.get("alias") or []
                    )

    @staticmethod
    def _extract_email_alias(aliases: list[dict]) -> str | None:
        for a in aliases:
            if a.get("type") == "EMAIL":
                return a.get("value")
        return None

    # ------------------------------------------------------------------
    # Account discovery
    # ------------------------------------------------------------------

    def discover_primary_account(self) -> int:
        """Fetch the user's primary monetary account and cache its id."""
        self.bunq_account_id = self.get_primary_account_id()
        return self.bunq_account_id

    # ------------------------------------------------------------------
    # Context persistence — DB row instead of bunq_context.json
    # ------------------------------------------------------------------

    def _row_dict(self) -> dict:
        assert self.user_id is not None and self.bunq_email is not None
        assert self.bunq_account_id is not None
        return {
            "user_id": self.supabase_user_id,
            "bunq_api_key": self.api_key,
            "bunq_user_id": self.user_id,
            "bunq_account_id": self.bunq_account_id,
            "bunq_email": self.bunq_email,
            "private_key_pem": self._private_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ).decode(),
            "installation_token": self.installation_token,
            "server_public_key": self.server_public_key,
            "session_token": self.session_token,
        }

    def _save_context(self) -> None:
        sb = get_sb()
        sb.table("customer_bunq_accounts").upsert(
            self._row_dict(), on_conflict="user_id"
        ).execute()
        log.info(
            "CustomerBunqClient: saved context user_id=%s bunq_user=%s email=%s",
            self.supabase_user_id, self.user_id, self.bunq_email,
        )

    def _load_row(self) -> dict | None:
        sb = get_sb()
        res = (
            sb.table("customer_bunq_accounts")
            .select("*")
            .eq("user_id", self.supabase_user_id)
            .maybe_single()
            .execute()
        )
        if res is None or not res.data:
            return None
        return res.data

    def _load_context(self) -> bool:
        row = self._load_row()
        if row is None:
            return False
        if row["bunq_api_key"] != self.api_key or not self.sandbox:
            # Sandbox-only is enforced by the constructor default; mismatched
            # key shouldn't happen in normal flow.
            return False
        try:
            self._private_key = serialization.load_pem_private_key(
                row["private_key_pem"].encode(), password=None,
            )
            self._public_key_pem = self._private_key.public_key().public_bytes(
                serialization.Encoding.PEM,
                serialization.PublicFormat.SubjectPublicKeyInfo,
            ).decode()
            self.installation_token = row["installation_token"]
            self.server_public_key = row["server_public_key"]
            self.session_token = row["session_token"]
            self.user_id = row["bunq_user_id"]
            self.bunq_email = row["bunq_email"]
            self.bunq_account_id = row["bunq_account_id"]
            return True
        except (KeyError, ValueError) as e:
            log.warning("CustomerBunqClient: failed to rehydrate row: %r", e)
            return False