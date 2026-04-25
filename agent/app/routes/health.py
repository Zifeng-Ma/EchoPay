"""Health check endpoint — no auth required."""

from fastapi import APIRouter

router = APIRouter()


@router.get("/health")
async def health() -> dict[str, str]:
    """
    Returns service liveness status.

    Used by:
    - Plan 01 boot smoke test
    - Flutter app to confirm agent is reachable before starting a chat session
    - Docker / cloud health probes (Plans 05+)
    """
    return {"status": "ok", "service": "echopay-agent"}