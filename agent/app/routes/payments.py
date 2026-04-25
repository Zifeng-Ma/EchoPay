"""
Thin HTTP layer over `bunq_service`. Pydantic models on the boundary; no
business logic here. Webhook route currently logs and ACKs — the Supabase
teammate plugs in order-status updates at the marked TODO.
"""

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
    bunq POSTs payment / mutation events here. For now: log and 200.
    """
    payload = await req.json()
    log.info("bunq webhook: %s", payload)
    # TODO(supabase teammate): parse payload["NotificationUrl"]["object"]
    # and flip orders.status to 'paid' when event indicates payment success.
    return {"ok": True}
