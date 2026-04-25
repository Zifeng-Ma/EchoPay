"""
Thin HTTP layer over `bunq_service`. Pydantic models on the boundary; no
business logic here. Webhook route currently logs and ACKs — the Supabase
teammate plugs in order-status updates at the marked TODO.
"""

import logging
from uuid import uuid4

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from app.services import bunq_service

router = APIRouter(prefix="/payments", tags=["payments"])
compat_router = APIRouter(tags=["payments"])
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


class InitiatePaymentBody(BaseModel):
    order_id: str
    amount_cents: int = Field(gt=0)
    currency: str = "EUR"
    description: str = "EchoPay Order"
    payer_email: str | None = None


@router.post("/request")
def create_request(body: RequestPaymentBody) -> dict:
    try:
        return bunq_service.request_payment(**body.model_dump())
    except Exception as e:
        log.exception("bunq request_payment failed")
        raise HTTPException(status_code=502, detail=f"bunq error: {e}")


@compat_router.post("/payment/initiate")
def initiate_payment_compat(body: InitiatePaymentBody) -> dict:
    """
    Compatibility shape for the current Flutter PaymentService.

    The mobile app does not yet collect a payer alias, so this route can only
    create a real bunq request when `payer_email` is supplied by a newer client.
    Otherwise it returns a stable transaction reference for the existing order
    polling flow.
    """
    if body.payer_email:
        try:
            result = bunq_service.request_payment(
                amount_cents=body.amount_cents,
                currency=body.currency,
                payer_email=body.payer_email,
                description=body.description,
            )
        except Exception as e:
            log.exception("bunq compatibility request failed")
            raise HTTPException(status_code=502, detail=f"bunq error: {e}")
        transaction_ref = str(result["request_id"])
        return {"transaction_ref": transaction_ref, **result}

    return {
        "transaction_ref": f"manual-{body.order_id}-{uuid4().hex[:8]}",
        "status": "pending_external_confirmation",
    }


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
    bunq POSTs payment / mutation events here. For now: log and 200.
    """
    payload = await req.json()
    log.info("bunq webhook: %s", payload)
    # TODO(supabase teammate): parse payload["NotificationUrl"]["object"]
    # and flip orders.status to 'paid' when event indicates payment success.
    return {"ok": True}
