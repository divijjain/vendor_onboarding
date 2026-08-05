"""Postgres checkpointer setup — own schema, own setup, not Ecto's migrations.

Shares the same Postgres instance as the Elixir app but writes to a
dedicated `langgraph` schema, so the two stacks' migrations never collide.
See CONTEXT.md's checkpointer-schema-ownership decision.

Async, because Agent 2's validation node calls the two MCP servers over
HTTP and the sync `PostgresSaver` doesn't implement the async checkpoint
methods LangGraph's `ainvoke` needs (`aget_tuple` raises `NotImplementedError`).
"""

import os

import psycopg
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver
from langgraph.checkpoint.serde.jsonplus import JsonPlusSerializer

SCHEMA = "langgraph"

# Checkpoint state holds our own ExtractionResult (app/schemas.py), so it must
# be explicitly allow-listed for msgpack deserialization — otherwise this
# warns now and will be rejected outright in a future langgraph-checkpoint version.
ALLOWED_MSGPACK_MODULES = [
    ("app.schemas", "ContractExtraction"),
    ("app.schemas", "W9Extraction"),
    ("app.schemas", "ValidationResult"),
    ("app.schemas", "EntityMatchResult"),
]


def database_url() -> str:
    return os.environ.get(
        "CHECKPOINTER_DATABASE_URL",
        "postgresql://postgres:postgres@localhost:5432/vendor_onboarding_dev",
    )


def _conn_string() -> str:
    return f"{database_url()}?options=-c%20search_path%3D{SCHEMA},public"


def ensure_schema() -> None:
    with psycopg.connect(database_url(), autocommit=True) as conn:
        conn.execute(f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")


def get_checkpointer():
    """Async context manager yielding an `AsyncPostgresSaver` scoped to the `langgraph` schema."""
    ensure_schema()
    serde = JsonPlusSerializer(allowed_msgpack_modules=ALLOWED_MSGPACK_MODULES)
    return AsyncPostgresSaver.from_conn_string(_conn_string(), serde=serde)
