"""
EchoPay Agent — FastAPI application entry point.

Boot with:
    cd agent
    uvicorn app.main:app --reload --port 8000

Health check:
    curl http://localhost:8000/health
    # → {"status": "ok", "service": "echopay-agent"}
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# Import settings at module load — this triggers env var validation.
# If any required var is missing, the process exits with a descriptive error
# before uvicorn starts accepting traffic. Intentional.
from app.config import settings  # noqa: F401
from app.routes import health, payments, voice

app = FastAPI(
    title="EchoPay Agent",
    description="AI-powered payment agent for bunq hackathon",
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    # Hackathon: allow all origins. Tighten to specific domains post-demo.
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router)
app.include_router(voice.router)
app.include_router(payments.router)
