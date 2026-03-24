#!/usr/bin/env bash
# api-test-scaffold.sh — Generate a pytest test file for a FastAPI router
#
# Usage: ./api-test-scaffold.sh <router-module-name> [output-dir]
# Example: ./api-test-scaffold.sh users
#          ./api-test-scaffold.sh products ./tests
#
# Generates:
#   <output-dir>/test_<router>.py — Test file with:
#     - TestClient / AsyncClient setup
#     - Auth fixture with token generation
#     - Test stubs for GET, POST, PUT, PATCH, DELETE
#     - Validation error tests
#     - Pagination tests
#
# Assumes standard project layout with app.main:app and app.core.security.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <router-module-name> [output-dir]"
    echo "Example: $0 users ./tests"
    exit 1
fi

ROUTER="$1"
OUTPUT_DIR="${2:-./tests}"
SNAKE="${ROUTER//-/_}"
CLASS="${SNAKE^}"
PLURAL="${SNAKE}s"

# If the name already ends in 's', use it as-is for the endpoint
if [[ "$SNAKE" == *s ]]; then
    PLURAL="$SNAKE"
fi

mkdir -p "$OUTPUT_DIR"

OUTFILE="$OUTPUT_DIR/test_${SNAKE}.py"

cat > "$OUTFILE" << PYEOF
"""Tests for the ${SNAKE} router.

Run with: pytest ${OUTFILE} -v
"""
import pytest
from httpx import ASGITransport, AsyncClient

from app.core.security import create_access_token
from app.main import app

BASE_URL = "/api/v1/${PLURAL}"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
async def client():
    """Async test client with lifespan support."""
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as c:
        yield c


@pytest.fixture
def auth_headers() -> dict[str, str]:
    """Authorization headers with a valid JWT token."""
    token = create_access_token(subject="test-user-id")
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def sample_${SNAKE}_data() -> dict:
    """Valid payload for creating a ${SNAKE}."""
    return {
        "name": "Test ${CLASS}",
        "description": "A test ${SNAKE} for automated tests",
    }


# ---------------------------------------------------------------------------
# GET — List
# ---------------------------------------------------------------------------

class TestList${CLASS}:
    @pytest.mark.anyio
    async def test_list_returns_200(self, client: AsyncClient, auth_headers):
        resp = await client.get(BASE_URL, headers=auth_headers)
        assert resp.status_code == 200

    @pytest.mark.anyio
    async def test_list_returns_paginated(self, client: AsyncClient, auth_headers):
        resp = await client.get(
            BASE_URL, headers=auth_headers, params={"page": 1, "size": 10}
        )
        assert resp.status_code == 200
        data = resp.json()
        assert "items" in data
        assert "total" in data
        assert "page" in data

    @pytest.mark.anyio
    async def test_list_invalid_page(self, client: AsyncClient, auth_headers):
        resp = await client.get(
            BASE_URL, headers=auth_headers, params={"page": 0}
        )
        assert resp.status_code == 422


# ---------------------------------------------------------------------------
# GET — Single
# ---------------------------------------------------------------------------

class TestGet${CLASS}:
    @pytest.mark.anyio
    async def test_get_existing(self, client: AsyncClient, auth_headers):
        # TODO: Create a ${SNAKE} first, then fetch it
        resp = await client.get(f"{BASE_URL}/1", headers=auth_headers)
        assert resp.status_code in (200, 404)

    @pytest.mark.anyio
    async def test_get_nonexistent_returns_404(self, client: AsyncClient, auth_headers):
        resp = await client.get(f"{BASE_URL}/99999", headers=auth_headers)
        assert resp.status_code == 404


# ---------------------------------------------------------------------------
# POST — Create
# ---------------------------------------------------------------------------

class TestCreate${CLASS}:
    @pytest.mark.anyio
    async def test_create_success(
        self, client: AsyncClient, auth_headers, sample_${SNAKE}_data
    ):
        resp = await client.post(
            BASE_URL, json=sample_${SNAKE}_data, headers=auth_headers
        )
        assert resp.status_code == 201
        data = resp.json()
        assert data["name"] == sample_${SNAKE}_data["name"]
        assert "id" in data

    @pytest.mark.anyio
    async def test_create_missing_required_field(
        self, client: AsyncClient, auth_headers
    ):
        resp = await client.post(BASE_URL, json={}, headers=auth_headers)
        assert resp.status_code == 422

    @pytest.mark.anyio
    async def test_create_unauthenticated(
        self, client: AsyncClient, sample_${SNAKE}_data
    ):
        resp = await client.post(BASE_URL, json=sample_${SNAKE}_data)
        assert resp.status_code in (401, 403)


# ---------------------------------------------------------------------------
# PATCH — Update
# ---------------------------------------------------------------------------

class TestUpdate${CLASS}:
    @pytest.mark.anyio
    async def test_update_success(self, client: AsyncClient, auth_headers):
        # TODO: Create a ${SNAKE} first, then update it
        resp = await client.patch(
            f"{BASE_URL}/1",
            json={"name": "Updated Name"},
            headers=auth_headers,
        )
        assert resp.status_code in (200, 404)

    @pytest.mark.anyio
    async def test_update_nonexistent_returns_404(
        self, client: AsyncClient, auth_headers
    ):
        resp = await client.patch(
            f"{BASE_URL}/99999",
            json={"name": "Updated"},
            headers=auth_headers,
        )
        assert resp.status_code == 404

    @pytest.mark.anyio
    async def test_partial_update(self, client: AsyncClient, auth_headers):
        # PATCH should accept partial data
        resp = await client.patch(
            f"{BASE_URL}/1",
            json={"description": "Updated description only"},
            headers=auth_headers,
        )
        assert resp.status_code in (200, 404)


# ---------------------------------------------------------------------------
# DELETE
# ---------------------------------------------------------------------------

class TestDelete${CLASS}:
    @pytest.mark.anyio
    async def test_delete_success(self, client: AsyncClient, auth_headers):
        # TODO: Create a ${SNAKE}, then delete it
        resp = await client.delete(f"{BASE_URL}/1", headers=auth_headers)
        assert resp.status_code in (204, 404)

    @pytest.mark.anyio
    async def test_delete_nonexistent_returns_404(
        self, client: AsyncClient, auth_headers
    ):
        resp = await client.delete(f"{BASE_URL}/99999", headers=auth_headers)
        assert resp.status_code == 404

    @pytest.mark.anyio
    async def test_delete_unauthenticated(self, client: AsyncClient):
        resp = await client.delete(f"{BASE_URL}/1")
        assert resp.status_code in (401, 403)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

class TestValidation:
    @pytest.mark.anyio
    async def test_invalid_content_type(self, client: AsyncClient, auth_headers):
        resp = await client.post(
            BASE_URL,
            content="not json",
            headers={**auth_headers, "Content-Type": "text/plain"},
        )
        assert resp.status_code == 422

    @pytest.mark.anyio
    async def test_name_too_long(self, client: AsyncClient, auth_headers):
        resp = await client.post(
            BASE_URL,
            json={"name": "x" * 1000},
            headers=auth_headers,
        )
        assert resp.status_code == 422
PYEOF

echo "✅ Generated test file: $OUTFILE"
echo ""
echo "Run tests with:"
echo "  pytest $OUTFILE -v"
