"""EchoPay bunq client — extends the vendored hackathon toolkit BunqClient
with the two methods Phase 1 needs.

DO NOT modify bunq/bunq_client.py (vendored, read-only).
All EchoPay-specific behaviour lives here.

Context file: the toolkit persists RSA key + session state to `bunq_context.json`
in the CURRENT WORKING DIRECTORY. Run scripts from agent/ so the file lands at
agent/bunq_context.json (which is gitignored by both root and agent/.gitignore).

Pitfall 1 mitigation: every exception logs the raw request body and the full
error repr — never just a status code — so opaque 401/403s are diagnosable
on demo day without a debugger.
"""

import logging
import sys
from pathlib import Path

# Make the vendored toolkit importable regardless of which directory the caller
# uses as CWD.  Repo root = three levels above this file's parent package.
REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bunq.bunq_client import BunqClient  # type: ignore[import]  # vendored

log = logging.getLogger(__name__)


class EchoPayBunqClient(BunqClient):
    """Phase 1 bunq surface — only the two methods we actually need.

    BUNQ-01: create_request_inquiry — called by agent's place_order tool.
    Plan 05:  register_callback_url — called once at deploy time to wire
              the Supabase Edge Function URL into bunq sandbox.
    """

    # ------------------------------------------------------------------
    # BUNQ-01 — create a payment request (RequestInquiry)
    # ------------------------------------------------------------------

    def create_request_inquiry(
        self,
        amount_eur: float,
        recipient_email: str,
        recipient_name: str,
        description: str,
    ) -> dict:
        """POST user/{user_id}/monetary-account/{account_id}/request-inquiry.

        Returns a dict with two keys:
          - "payment_id": str  — the bunq request ID; store as orders.bunq_payment_id
          - "raw":        list — the full bunq response (for debugging / logging)

        Recipient: in sandbox use "sugardaddy@bunq.com" (auto-pays immediately).
        In production: the customer's registered bunq email address.

        Raises RuntimeError on unexpected response shape (see extract_payment_id).
        Re-raises requests.HTTPError on HTTP failure (with full body logged).
        """
        account_id = self.get_primary_account_id()
        body = {
            "amount_inquired": {"value": f"{amount_eur:.2f}", "currency": "EUR"},
            "counterparty_alias": {
                "type": "EMAIL",
                "value": recipient_email,
                "name": recipient_name,
            },
            "description": description,
            "allow_bunqme": False,
        }
        endpoint = f"user/{self.user_id}/monetary-account/{account_id}/request-inquiry"
        log.info(
            "bunq RequestInquiry: POST %s body=%s",
            endpoint,
            body,
        )
        try:
            resp = self.post(endpoint, body)
        except Exception as exc:
            # PITFALLS Pitfall 1: log the full body sent + error repr.
            # Never swallow — the raw message is the only way to diagnose
            # opaque 401/403s without a bunq support ticket.
            log.error(
                "bunq RequestInquiry FAILED. endpoint=%s body=%s error=%s",
                endpoint,
                body,
                repr(exc),
            )
            raise

        payment_id = self.extract_payment_id(resp)
        log.info("bunq RequestInquiry OK: payment_id=%s", payment_id)
        return {"raw": resp, "payment_id": payment_id}

    # ------------------------------------------------------------------
    # Plan 05 — register the Edge Function URL as a bunq notification filter
    # ------------------------------------------------------------------

    def register_callback_url(self, callback_url: str) -> list:
        """POST user/{user_id}/notification-filter-url.

        Registers PAYMENT + MUTATION categories pointing at callback_url.
        Called once at deploy time (Plan 05) to wire the Supabase Edge Function.
        During smoke-test (Plan 03) we pass httpbin.org/post as a no-op target.

        Source: bunq/07_setup_callbacks.py — exact POST shape mirrored here.

        Returns the raw bunq response list.
        """
        body = {
            "notification_filters": [
                {"category": "PAYMENT", "notification_target": callback_url},
                {"category": "MUTATION", "notification_target": callback_url},
            ]
        }
        endpoint = f"user/{self.user_id}/notification-filter-url"
        log.info("bunq register_callback_url: POST %s url=%s", endpoint, callback_url)
        try:
            resp = self.post(endpoint, body)
        except Exception as exc:
            log.error(
                "bunq register_callback_url FAILED. endpoint=%s url=%s error=%s",
                endpoint,
                callback_url,
                repr(exc),
            )
            raise
        log.info("bunq register_callback_url OK")
        return resp

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def extract_payment_id(resp: list) -> str:
        """Extract the bunq request ID from a RequestInquiry response.

        bunq response shape (from 04_request_money.py reference script):
            [{"Id": {"id": <int>}, ...}, ...]

        Coerces to str because orders.bunq_payment_id is a TEXT column.
        Raises RuntimeError if the shape doesn't match — better to fail loudly
        here than to store None and confuse the webhook lookup later.
        """
        try:
            return str(resp[0]["Id"]["id"])
        except (KeyError, IndexError, TypeError) as exc:
            raise RuntimeError(
                f"Unexpected bunq RequestInquiry response shape — cannot extract "
                f"payment_id. Full response: {resp!r}"
            ) from exc