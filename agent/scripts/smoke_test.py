"""
End-to-end smoke test against the real bunq sandbox.

Exercises the full path: auth handshake → request inquiry (funds the account
via sugardaddy auto-accept) → poll status → direct payment (sends some of
that balance back). If any step fails, the script prints bunq's actual error
body so you can fix it.

Prerequisites:
    - agent/.env contains BUNQ_API_KEY (a sandbox key)
    - pip install requests cryptography  (deps not yet in pyproject.toml)

Run:
    cd agent
    python -m scripts.smoke_test
"""

from __future__ import annotations

import sys
import time
import traceback

import requests

from app.services import bunq_service


COUNTERPARTY = "sugardaddy@bunq.com"


def _step(name: str) -> None:
    print(f"\n=== {name} ===")


def _report_failure(e: Exception) -> None:
    """Print bunq's JSON error body if the failure is an HTTPError."""
    print(f"  FAILED: {e}")
    if isinstance(e, requests.HTTPError) and e.response is not None:
        try:
            body = e.response.json()
            errs = body.get("Error") or body
            print(f"  bunq says: {errs}")
        except ValueError:
            print(f"  body: {e.response.text[:500]}")
    traceback.print_exc()


def main() -> int:
    failures: list[str] = []

    # Step 1: auth handshake (lazy — first call to _get_client triggers it)
    _step("1/4  Auth handshake")
    try:
        client, account_id = bunq_service._get_client()
        print(f"  user_id={client.user_id}  account_id={account_id}  OK")
    except Exception as e:
        _report_failure(e)
        return 1

    # Step 2: request inquiry (€1.00 from sugardaddy — auto-accepts, funds us)
    _step("2/4  Request inquiry — €1.00 from sugardaddy")
    request_id: int | None = None
    try:
        resp = bunq_service.request_payment(
            amount_cents=100,
            currency="EUR",
            payer_email=COUNTERPARTY,
            description="EchoPay smoke test — request inquiry",
        )
        request_id = resp["request_id"]
        print(f"  request_id={request_id}  status={resp['status']}  OK")
    except Exception as e:
        _report_failure(e)
        failures.append("request_payment")

    # Step 3: poll status until sugardaddy accepts (~1-2s)
    _step("3/4  Poll request status until ACCEPTED")
    accepted = False
    if request_id is None:
        print("  SKIPPED (request_payment failed)")
        failures.append("get_request_status")
    else:
        try:
            for attempt in range(8):
                time.sleep(1)
                status = bunq_service.get_request_status(request_id)
                print(f"  attempt {attempt + 1}: {status}")
                if status["status"] == "ACCEPTED":
                    accepted = True
                    break
                if status["status"] in ("REJECTED", "REVOKED", "EXPIRED"):
                    break
            if not accepted:
                print("  WARN: never reached ACCEPTED (sandbox slow or rejected)")
        except Exception as e:
            _report_failure(e)
            failures.append("get_request_status")

    # Step 4: direct payment (€0.10 → sugardaddy) — only after we have balance
    _step("4/4  Direct payment — €0.10 → sugardaddy")
    if not accepted:
        print("  SKIPPED (no incoming funds; account would have €0 balance)")
        failures.append("make_payment")
    else:
        try:
            resp = bunq_service.make_payment(
                amount_cents=10,
                currency="EUR",
                recipient_email=COUNTERPARTY,
                description="EchoPay smoke test — direct payment",
            )
            print(f"  payment_id={resp['payment_id']}  OK")
        except Exception as e:
            _report_failure(e)
            failures.append("make_payment")

    # Summary
    print("\n" + "=" * 60)
    if failures:
        print(f"FAILED: {len(failures)} step(s) — {', '.join(failures)}")
        return 1
    print("ALL STEPS PASSED  ✓  bunq integration is working")
    return 0


if __name__ == "__main__":
    sys.exit(main())
