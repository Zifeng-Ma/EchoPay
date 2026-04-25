# bunq Payment Integration — Implementation Plan

This is a self-contained plan for wiring bunq sandbox payments into the EchoPay agent.

The plan is built around the toolkit at https://github.com/bunq/hackathon_toolkit — specifically scripts `03_make_payment.py`, `04_request_money.py`, `07_setup_callbacks.py`, and `bunq_client.py`.

---

## 0. The flow we're building

```
Customer says "place the order" in voice/chat
        │
        ▼
Agent calls place_order(cart_id) tool
        │
        ▼
agent/app/services/bunq_service.py
  → request_payment(amount_cents, currency, payer_email, description)
        │
        ▼
bunq sandbox creates a RequestInquiry
        │
   ┌────┴─────┐
   │          │
   ▼          ▼
order row    bunq webhook fires when paid
saved with        │
bunq_request_id   ▼
              POST /payments/webhook
                  │
                  ▼
           Edge Function flips orders.status → 'paid'
                  │
                  ▼
        Supabase Realtime → both apps update
```

Two payment paths exist; we ship both because each has demo value:

| Path | Endpoint | Use |
|---|---|---|
| `RequestInquiry` (script 04) | `POST /v1/user/{u}/monetary-account/{a}/request-inquiry` | The "real" flow — customer accepts the request from their bunq sandbox account. More authentic; needs the customer to be a real sandbox user. |
| Direct `Payment` (script 03) | `POST /v1/user/{u}/monetary-account/{a}/payment` | Demo shortcut — agent pays directly from the pre-funded restaurant sandbox account. Fast, deterministic, one-tap on stage. |

Build both. Decide on demo day which one to call from `place_order`.

---

## 1. Vendor `bunq_client.py` into `/bunq/`

The toolkit is a script collection, not a pip package. Just copy the one file we need and delete the placeholder.

```bash
cp /Users/andywei/hackathon_toolkit/bunq_client.py bunq/bunq_client.py
rm bunq/.gitkeep
```

Do **not** modify `bunq_client.py` — keep it pristine so updates upstream are easy to pull in. All extensions live in `agent/app/services/bunq_service.py`.

Add a one-line `bunq/README.md` if you want, noting "vendored from bunq/hackathon_toolkit @ main".

---

## 2. Add toolkit deps + env vars

### `agent/pyproject.toml`

Add to the `dependencies` list:

```toml
"requests>=2.28",
"cryptography>=41.0",
```

Then `cd agent && pip install -e .` (or `uv sync` if using uv).

### `agent/.env.example`

Append:

```
# --- bunq sandbox ---
BUNQ_API_KEY=
BUNQ_USE_SANDBOX=true
# Set after `ngrok http 8000` on demo day:
BUNQ_WEBHOOK_URL=
```

### `agent/app/config.py`

`BUNQ_API_KEY` and `BUNQ_WEBHOOK_URL` are already validated. Add one line for the sandbox flag:

```python
self.bunq_use_sandbox: bool = os.environ.get("BUNQ_USE_SANDBOX", "true").lower() == "true"
```

### `agent/.gitignore`

Add `bunq_context.json` — `bunq_client.py` writes the cached session token there in CWD. Never commit it.

---

## 3. Build the wrapper: `agent/app/services/bunq_service.py`

This is the **only** file your teammates import. It hides every HTTP detail.

### Contract (the public API)

```python
def request_payment(
    amount_cents: int,
    currency: str,           # "EUR"
    payer_email: str,        # the customer's sandbox email
    description: str,
) -> dict:
    """
    Create a RequestInquiry from the restaurant's sandbox account to the
    customer. Returns {"request_id": int, "status": str}.
    Used by the agent's place_order tool when we want the customer to
    explicitly approve the payment in their bunq app.
    """

def make_payment(
    amount_cents: int,
    currency: str,
    recipient_email: str,    # restaurant's email; in demo shortcut, the agent pays from the customer's pre-funded account
    description: str,
) -> dict:
    """
    Direct Payment — no approval step. Returns {"payment_id": int}.
    Used as the demo shortcut when we want the place_order tool to settle
    the bill in one tap.
    """

def get_request_status(request_id: int) -> dict:
    """
    Poll a RequestInquiry by id. Returns {"status": str, "amount": str, "currency": str}.
    Statuses: PENDING, ACCEPTED, REJECTED, REVOKED, EXPIRED.
    """

def register_webhook(callback_url: str) -> None:
    """
    Register PAYMENT + MUTATION callbacks pointing at our /payments/webhook.
    Called once at deploy time by scripts/register_webhook.py — not at request time.
    """
```

### Implementation sketch

Two implementation notes that matter:

1. **Singleton client.** `bunq_client.BunqClient.authenticate()` does the 3-step handshake (installation → device → session). Session-server is rate limited to **1/30s**. Do this **once** at process start and reuse, never per-request.
2. **Amounts.** Store cents internally everywhere in our app. Convert to bunq's `"X.XX"` strings only at this boundary. Never let `float` near currency.

```python
# agent/app/services/bunq_service.py
import sys
from pathlib import Path
from threading import Lock

# /bunq isn't a pip package — add it to sys.path once
_BUNQ_DIR = Path(__file__).resolve().parents[3] / "bunq"
if str(_BUNQ_DIR) not in sys.path:
    sys.path.insert(0, str(_BUNQ_DIR))

from bunq_client import BunqClient  # noqa: E402
from app.config import settings

_client: BunqClient | None = None
_account_id: int | None = None
_lock = Lock()


def _get_client() -> tuple[BunqClient, int]:
    """Return the authenticated singleton + cached primary account id."""
    global _client, _account_id
    with _lock:
        if _client is None:
            c = BunqClient(api_key=settings.bunq_api_key, sandbox=settings.bunq_use_sandbox)
            c.authenticate()
            _client = c
            _account_id = c.get_primary_account_id()
        return _client, _account_id  # type: ignore[return-value]


def _fmt(amount_cents: int) -> str:
    if amount_cents < 0:
        raise ValueError("amount_cents must be >= 0")
    return f"{amount_cents // 100}.{amount_cents % 100:02d}"


def request_payment(amount_cents: int, currency: str, payer_email: str, description: str) -> dict:
    c, acc = _get_client()
    resp = c.post(
        f"user/{c.user_id}/monetary-account/{acc}/request-inquiry",
        {
            "amount_inquired": {"value": _fmt(amount_cents), "currency": currency},
            "counterparty_alias": {"type": "EMAIL", "value": payer_email, "name": payer_email},
            "description": description,
            "allow_bunqme": False,
        },
    )
    return {"request_id": resp[0]["Id"]["id"], "status": "PENDING"}


def make_payment(amount_cents: int, currency: str, recipient_email: str, description: str) -> dict:
    c, acc = _get_client()
    resp = c.post(
        f"user/{c.user_id}/monetary-account/{acc}/payment",
        {
            "amount": {"value": _fmt(amount_cents), "currency": currency},
            "counterparty_alias": {"type": "EMAIL", "value": recipient_email, "name": recipient_email},
            "description": description,
        },
    )
    return {"payment_id": resp[0]["Id"]["id"]}


def get_request_status(request_id: int) -> dict:
    c, acc = _get_client()
    resp = c.get(f"user/{c.user_id}/monetary-account/{acc}/request-inquiry/{request_id}")
    r = resp[0]["RequestInquiry"]
    return {
        "status": r["status"],
        "amount": r["amount_inquired"]["value"],
        "currency": r["amount_inquired"]["currency"],
    }


def register_webhook(callback_url: str) -> None:
    c, _ = _get_client()
    c.post(
        f"user/{c.user_id}/notification-filter-url",
        {
            "notification_filters": [
                {"category": "PAYMENT", "notification_target": callback_url},
                {"category": "MUTATION", "notification_target": callback_url},
                {"category": "REQUEST", "notification_target": callback_url},
            ],
        },
    )
```

---

## 4. Add `/payments` routes — `agent/app/routes/payments.py`

Thin HTTP layer over the wrapper. Pydantic models on the boundary; no business logic here.

```python
# agent/app/routes/payments.py
import logging
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from app.services import bunq_service

router = APIRouter(prefix="/payments", tags=["payments"])
log = logging.getLogger(__name__)


class RequestPaymentBody(BaseModel):
    amount_cents: int = Field(gt=0)
    currency: str = "EUR"
    payer_email: str
    description: str


class DirectPaymentBody(BaseModel):
    amount_cents: int = Field(gt=0)
    currency: str = "EUR"
    recipient_email: str
    description: str


@router.post("/request")
def create_request(body: RequestPaymentBody) -> dict:
    try:
        return bunq_service.request_payment(**body.model_dump())
    except Exception as e:
        log.exception("bunq request_payment failed")
        raise HTTPException(status_code=502, detail=f"bunq error: {e}")


@router.post("/direct")
def create_direct_payment(body: DirectPaymentBody) -> dict:
    try:
        return bunq_service.make_payment(**body.model_dump())
    except Exception as e:
        log.exception("bunq make_payment failed")
        raise HTTPException(status_code=502, detail=f"bunq error: {e}")


@router.get("/request/{request_id}")
def get_request(request_id: int) -> dict:
    try:
        return bunq_service.get_request_status(request_id)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"bunq error: {e}")


@router.post("/webhook")
async def bunq_webhook(req: Request) -> dict:
    """
    bunq POSTs payment / mutation / request events here.
    For now: log and return 200.
    The Supabase teammate plugs in: parse NotificationUrl payload →
    look up order by bunq_request_id or bunq_payment_id → flip status to 'paid'.
    """
    payload = await req.json()
    log.info("bunq webhook: %s", payload)
    # TODO(supabase teammate): update orders.status when event indicates payment success
    return {"ok": True}
```

### Wire it in `agent/app/main.py`

```python
from app.routes import health, payments  # add payments

app.include_router(health.router)
app.include_router(payments.router)
```

---

## 5. Operational scripts — `agent/scripts/`

Two one-off scripts. Run them by hand; they're not part of the running service.

### `agent/scripts/seed_funds.py`

Mirrors script 03 — funds the restaurant sandbox account so it can receive payments / send refunds. Run **once** after creating a fresh sandbox API key.

```python
"""Seed the sandbox account with EUR 500 from sugardaddy@bunq.com. Run once."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bunq"))

from app.services import bunq_service  # noqa: E402

resp = bunq_service.request_payment(
    amount_cents=50000,
    currency="EUR",
    payer_email="sugardaddy@bunq.com",
    description="EchoPay sandbox seed funds",
)
print(f"Seed request created: {resp}")
```

### `agent/scripts/register_webhook.py`

Mirrors script 07 — points bunq at our webhook URL. Run after `ngrok http 8000` on demo day.

```python
"""Register bunq webhook → /payments/webhook. Run after starting ngrok."""
from app.config import settings
from app.services import bunq_service

if not settings.bunq_webhook_url:
    raise SystemExit("Set BUNQ_WEBHOOK_URL in agent/.env first (e.g. https://abc123.ngrok.io/payments/webhook)")

bunq_service.register_webhook(settings.bunq_webhook_url)
print(f"Registered: {settings.bunq_webhook_url}")
```

Run with:

```bash
cd agent
python -m scripts.seed_funds
python -m scripts.register_webhook
```

---

## 6. Verification — the smoke test

Run these in order. If any step fails, fix before moving on; later steps depend on earlier ones.

### 6a. Auth handshake works

```bash
cd agent
uvicorn app.main:app --reload --port 8000
# in another shell:
curl http://localhost:8000/health
# → {"status":"ok","service":"echopay-agent"}
```

The first call to any `/payments/*` endpoint triggers the 3-step bunq handshake. Watch the agent logs — you should see the toolkit write `bunq_context.json` in the agent CWD. Subsequent calls are fast.

### 6b. Direct payment works

```bash
curl -X POST http://localhost:8000/payments/direct \
  -H "Content-Type: application/json" \
  -d '{"amount_cents": 1000, "currency": "EUR", "recipient_email": "sugardaddy@bunq.com", "description": "smoke test"}'
# → {"payment_id": 123456}
```

If that returns a payment_id, your auth + signing + endpoint are all working. This is the most important checkpoint.

### 6c. RequestInquiry works

```bash
curl -X POST http://localhost:8000/payments/request \
  -H "Content-Type: application/json" \
  -d '{"amount_cents": 2500, "currency": "EUR", "payer_email": "sugardaddy@bunq.com", "description": "smoke test request"}'
# → {"request_id": 789, "status": "PENDING"}

curl http://localhost:8000/payments/request/789
# → {"status": "ACCEPTED", "amount": "25.00", "currency": "EUR"}
# (sugardaddy auto-accepts requests in sandbox)
```

### 6d. Webhook fires

```bash
ngrok http 8000
# copy the https URL, set BUNQ_WEBHOOK_URL=https://abc.ngrok.io/payments/webhook in .env
# restart uvicorn
python -m scripts.register_webhook
# now repeat 6b — you should see the webhook payload in agent logs within a second
```

---

## 7. Handoff contract — what teammates need from us

When you commit this, message the team with these three bullets:

- **Agent person (place_order tool):** call `await asyncio.to_thread(bunq_service.request_payment, amount_cents, "EUR", payer_email, f"Order #{order_id}")`. Save the returned `request_id` to `orders.bunq_payment_id`. Use `make_payment` instead if you want the demo shortcut.
- **Supabase / Edge Function person:** the webhook lands at `POST /payments/webhook`. Parse `payload["NotificationUrl"]["object"]` — for `RequestInquiry` the `id` matches what we stored as `bunq_payment_id`; flip `orders.status` to `paid`. The route currently logs and returns 200 — search for the `TODO(supabase teammate)` line.
- **Flutter person (customer app):** subscribe to the `orders` row by id; when `status` flips to `pending_payment` show a confirmation sheet, when it flips to `paid` show success. The actual user-facing "approve" tap happens **inside the bunq sandbox app**, not in EchoPay (this is intentional — that's how PSD2 SCA works in production too).

---

## 8. Things to know / gotchas

- **Sandbox rate limits:** GET 3/3s, POST 5/3s, PUT 2/3s, session-server 1/30s. The singleton client makes session-server a non-issue; the others matter only if you spam endpoints in tests.
- **`bunq_context.json`:** persisted in CWD by the toolkit. It contains the session token + the RSA private key. **Never commit it.** Already gitignored above. If your auth gets weird, delete it and let the next call re-handshake.
- **Sandbox emails:** sandbox accounts are identified by email. Pre-create two sandbox users (the toolkit does this on first run) — one will be the "restaurant", one will be the "customer". Note their emails; they go into the `payer_email` / `recipient_email` fields.
- **`sugardaddy@bunq.com`:** auto-accepts up to 500 EUR per request and auto-pays your direct payments back. Use it as the test counterparty everywhere until you have two real sandbox users.
- **Currency:** sandbox is EUR-only.
- **No real money, ever:** keep `BUNQ_USE_SANDBOX=true` checked into `.env.example`. The toolkit defaults to sandbox but be explicit.

---

## File-by-file checklist

- [ ] `bunq/bunq_client.py` ← copied from toolkit
- [ ] `bunq/.gitkeep` ← deleted
- [ ] `agent/pyproject.toml` ← `requests` + `cryptography` added
- [ ] `agent/.env.example` ← bunq vars added
- [ ] `agent/.gitignore` ← `bunq_context.json` ignored
- [ ] `agent/app/config.py` ← `bunq_use_sandbox` field added
- [ ] `agent/app/services/__init__.py` ← created (empty)
- [ ] `agent/app/services/bunq_service.py` ← wrapper implemented
- [ ] `agent/app/routes/payments.py` ← routes implemented
- [ ] `agent/app/main.py` ← `payments.router` included
- [ ] `agent/scripts/__init__.py` ← created (empty)
- [ ] `agent/scripts/seed_funds.py`
- [ ] `agent/scripts/register_webhook.py`
- [ ] Smoke test 6a–6d all green
