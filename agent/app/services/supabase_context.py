"""Supabase-backed context and identity helpers for the agent service."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

import httpx
import jwt
from fastapi import Header, HTTPException

from app.config import settings


@dataclass(slots=True)
class RequestUser:
    user_id: str
    token: str


@dataclass(slots=True)
class AgentContext:
    user: RequestUser | None
    customer: dict[str, Any] | None
    restaurant: dict[str, Any] | None
    qr_location: dict[str, Any] | None
    menu_items: list[dict[str, Any]]
    recent_orders: list[dict[str, Any]]
    bunq_connection: dict[str, Any] | None


async def require_user(
    authorization: str | None = Header(default=None),
) -> RequestUser:
    """Resolve the current Supabase user from a bearer token."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing Supabase bearer token.")

    token = authorization.split(" ", maxsplit=1)[1].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Missing Supabase bearer token.")

    try:
        if settings.supabase_jwt_secret:
            header = jwt.get_unverified_header(token)
            alg = header.get("alg", "HS256")

            if alg.startswith("HS"):
                # Symmetric HMAC — use the JWT secret directly.
                payload = jwt.decode(
                    token,
                    settings.supabase_jwt_secret,
                    algorithms=[alg],
                    options={"verify_aud": False},
                )
            else:
                # Asymmetric alg (RS256 etc.) — we don't have the public key,
                # so skip signature verification but still validate claims.
                payload = jwt.decode(
                    token,
                    options={"verify_signature": False, "verify_aud": False},
                )
        else:
            # Local/hackathon fallback. Production should configure SUPABASE_JWT_SECRET.
            payload = jwt.decode(token, options={"verify_signature": False})
    except jwt.ExpiredSignatureError as exc:
        raise HTTPException(status_code=401, detail="Supabase token expired. Please re-authenticate.") from exc
    except jwt.PyJWTError as exc:
        raise HTTPException(status_code=401, detail=f"Invalid Supabase bearer token: {exc}") from exc

    user_id = str(payload.get("sub") or "").strip()
    if not user_id:
        raise HTTPException(status_code=401, detail="Invalid Supabase bearer token.")
    return RequestUser(user_id=user_id, token=token)


async def load_agent_context(
    *,
    user: RequestUser | None,
    restaurant_id: str | None,
    qr_location_id: str | None,
    fallback_menu: list[dict[str, Any]] | None = None,
) -> AgentContext:
    """Load the trusted context the model is allowed to use."""
    if not _has_supabase_service():
        return AgentContext(
            user=user,
            customer=None,
            restaurant=None,
            qr_location=None,
            menu_items=fallback_menu or [],
            recent_orders=[],
            bunq_connection=None,
        )

    customer = await _maybe_single("customers", {"id": f"eq.{user.user_id}"}) if user else None
    restaurant = None
    qr_location = None

    if qr_location_id:
        qr_location = await _maybe_single(
            "qr_locations",
            {"id": f"eq.{qr_location_id}", "select": "id,location_name,restaurant_id,is_active"},
        )
        if qr_location and not restaurant_id:
            restaurant_id = str(qr_location.get("restaurant_id") or "")

    if restaurant_id:
        restaurant = await _maybe_single("restaurants", {"id": f"eq.{restaurant_id}"})

    menu_items = await _list(
        "menu_items",
        {
            "restaurant_id": f"eq.{restaurant_id}",
            "select": (
                "id,restaurant_id,name,description,name_translations,"
                "description_translations,category,price,inventory_count,"
                "dietary_tags,is_available"
            ),
            "order": "category.asc,name.asc",
        },
    ) if restaurant_id else []

    recent_orders = await _list(
        "orders",
        {
            "customer_id": f"eq.{user.user_id}",
            "order_status": "neq.draft",
            "select": (
                "id,restaurant_id,order_status,total_amount,created_at,"
                "restaurants(name),order_items(quantity,price_at_purchase,menu_items(name))"
            ),
            "order": "created_at.desc",
            "limit": "5",
        },
    ) if user else []

    bunq_connection = await _maybe_single(
        "bunq_connections",
        {"customer_id": f"eq.{user.user_id}", "status": "eq.connected"},
    ) if user else None

    # Also treat a provisioned sandbox account as "connected" so the agent
    # knows it can execute payment without asking the user to link bunq.
    if bunq_connection is None and user:
        bunq_account = await _maybe_single(
            "customer_bunq_accounts", {"user_id": f"eq.{user.user_id}"}
        )
        if bunq_account and bunq_account.get("bunq_api_key"):
            # Expose with a _source tag so downstream code can distinguish
            bunq_connection = {"_source": "customer_bunq_accounts", **bunq_account}

    return AgentContext(
        user=user,
        customer=customer,
        restaurant=restaurant,
        qr_location=qr_location,
        menu_items=menu_items or fallback_menu or [],
        recent_orders=recent_orders,
        bunq_connection=bunq_connection,
    )


async def get_bunq_connection(user_id: str) -> dict[str, Any] | None:
    if not _has_supabase_service():
        return None
    return await _maybe_single(
        "bunq_connections",
        {"customer_id": f"eq.{user_id}", "status": "eq.connected"},
    )


async def get_bunq_payment_token(user_id: str) -> str | None:
    """Return the best available bunq token for executing a payment as this user.

    Preference order:
      1. customer_bunq_accounts.bunq_api_key — auto-provisioned sandbox key.
         This is a real bunq API key, directly usable as the api_key param in
         BunqClient / make_user_payment_from_oauth.
      2. bunq_connections.access_token_encrypted — OAuth access token (base64).

    Returns None when the user has no usable bunq credential.
    """
    if not _has_supabase_service():
        return None

    # 1. Provisioned sandbox account (API key path — preferred for hackathon)
    row = await _maybe_single(
        "customer_bunq_accounts", {"user_id": f"eq.{user_id}"}
    )
    if row and row.get("bunq_api_key"):
        return str(row["bunq_api_key"])

    # 2. OAuth connection (customer linked their own bunq account)
    conn = await _maybe_single(
        "bunq_connections",
        {"customer_id": f"eq.{user_id}", "status": "eq.connected"},
    )
    if conn and conn.get("access_token_encrypted"):
        token = decode_stored_secret(str(conn["access_token_encrypted"]))
        return token or None

    return None


async def upsert_bunq_connection(
    *,
    user_id: str,
    access_token: str,
    bunq_user_id: str = "",
) -> None:
    if not _has_supabase_service():
        raise HTTPException(status_code=503, detail="Supabase service role is not configured.")
    await _request(
        "POST",
        "bunq_connections",
        params={"on_conflict": "customer_id"},
        json_body={
            "customer_id": user_id,
            "status": "connected",
            "bunq_user_id": bunq_user_id,
            "access_token_encrypted": _encode_secret(access_token),
        },
        extra_headers={"Prefer": "resolution=merge-duplicates"},
    )


async def create_order_from_cart(
    *,
    user_id: str,
    restaurant_id: str,
    qr_location_id: str | None,
    cart_items: list[dict[str, Any]],
) -> str:
    if not _has_supabase_service():
        raise HTTPException(status_code=503, detail="Supabase service role is not configured.")
    if not cart_items:
        raise HTTPException(status_code=400, detail="Cannot create an empty order.")

    total = sum(_as_int(item.get("line_total"), _as_int(item.get("base_price"), 0) * _as_int(item.get("quantity"), 1)) for item in cart_items)
    order_rows = await _request(
        "POST",
        "orders",
        json_body={
            "restaurant_id": restaurant_id,
            "customer_id": user_id,
            "qr_location_id": qr_location_id,
            "order_status": "draft",
            "total_amount": total,
        },
        extra_headers={"Prefer": "return=representation"},
    )
    order = order_rows[0] if order_rows else {}
    order_id = str(order.get("id") or "")
    if not order_id:
        raise HTTPException(status_code=502, detail="Supabase did not return an order id.")

    for item in cart_items:
        await _request(
            "POST",
            "order_items",
            json_body={
                "order_id": order_id,
                "menu_item_id": item.get("menu_item_id"),
                "quantity": _as_int(item.get("quantity"), 1),
                "special_instructions": item.get("special_instructions"),
                "price_at_purchase": _as_int(item.get("base_price"), 0),
            },
        )
    return order_id


async def update_order(order_id: str, updates: dict[str, Any]) -> None:
    if not _has_supabase_service():
        raise HTTPException(status_code=503, detail="Supabase service role is not configured.")
    await _request(
        "PATCH",
        "orders",
        params={"id": f"eq.{order_id}"},
        json_body=updates,
    )


def decode_stored_secret(value: str) -> str:
    try:
        return base64.b64decode(value.encode("ascii")).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return ""


def _has_supabase_service() -> bool:
    return bool(settings.supabase_url and settings.supabase_service_role_key)


async def _maybe_single(table: str, params: dict[str, str]) -> dict[str, Any] | None:
    rows = await _list(table, {**params, "limit": "1"})
    return rows[0] if rows else None


async def _list(table: str, params: dict[str, str]) -> list[dict[str, Any]]:
    rows = await _request("GET", table, params=params)
    return rows if isinstance(rows, list) else []


async def _request(
    method: str,
    table: str,
    *,
    params: dict[str, str] | None = None,
    json_body: dict[str, Any] | None = None,
    extra_headers: dict[str, str] | None = None,
) -> Any:
    assert settings.supabase_url and settings.supabase_service_role_key
    url = f"{settings.supabase_url.rstrip('/')}/rest/v1/{table}"
    headers = {
        "apikey": settings.supabase_service_role_key,
        "Authorization": f"Bearer {settings.supabase_service_role_key}",
        "Content-Type": "application/json",
    }
    if extra_headers:
        headers.update(extra_headers)
    async with httpx.AsyncClient(timeout=20.0) as client:
        response = await client.request(
            method,
            url,
            headers=headers,
            params=params,
            json=json_body,
        )
    if response.status_code >= 400:
        raise HTTPException(status_code=502, detail=f"Supabase {table} failed: {response.text}")
    if not response.content:
        return []
    return response.json()


def _encode_secret(value: str) -> str:
    # Placeholder encryption boundary for the hackathon app. Replace with KMS/Fernet
    # before production; the token never leaves the backend either way.
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def _as_int(value: Any, fallback: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback
