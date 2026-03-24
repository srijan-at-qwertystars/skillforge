"""
Meilisearch Python Search Client
=================================

A production-ready wrapper around the ``meilisearch`` Python SDK providing:

* Client initialisation with connection validation
* Index & document management (CRUD, bulk import with batching)
* Search helpers (basic, filtered, faceted, geo, hybrid)
* Multi-search across indexes
* Task monitoring & waiting
* Backup utilities (dump creation)
* Tenant-token generation
* CLI interface for common operations

Usage as a library::

    from search_client import MeiliClient

    client = MeiliClient("http://localhost:7700", "masterKey")
    client.add_documents("products", [{"id": 1, "name": "Keyboard"}])
    results = client.search("products", "keyboard")

Usage from the command line::

    python search_client.py search products "mechanical keyboard"
    python search_client.py import products products.json --batch-size 500
    python search_client.py backup
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional, Sequence

import meilisearch
from meilisearch.errors import MeilisearchApiError, MeilisearchError

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logger = logging.getLogger("meilisearch_client")


def configure_logging(level: int = logging.INFO) -> None:
    """Set up structured logging for the client."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        logging.Formatter(
            "%(asctime)s [%(levelname)s] %(name)s – %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
    )
    logger.addHandler(handler)
    logger.setLevel(level)


# ---------------------------------------------------------------------------
# Custom Exceptions
# ---------------------------------------------------------------------------


class ClientError(Exception):
    """Base exception for client-level errors."""


class ConnectionError(ClientError):  # noqa: A001 – intentional shadow
    """Raised when the client cannot reach Meilisearch."""


class IndexNotFoundError(ClientError):
    """Raised when an index does not exist."""


class TaskFailedError(ClientError):
    """Raised when a Meilisearch task terminates with an error."""

    def __init__(self, task_uid: int, error: dict[str, Any]) -> None:
        self.task_uid = task_uid
        self.error = error
        super().__init__(f"Task {task_uid} failed: {error.get('message', error)}")


# ---------------------------------------------------------------------------
# Task Info Helper
# ---------------------------------------------------------------------------


@dataclass
class TaskInfo:
    """Lightweight representation of a Meilisearch task."""

    uid: int
    status: str
    type: str
    index_uid: Optional[str] = None
    error: Optional[dict[str, Any]] = None
    duration: Optional[str] = None
    enqueued_at: Optional[str] = None
    started_at: Optional[str] = None
    finished_at: Optional[str] = None
    details: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Main Client
# ---------------------------------------------------------------------------


class MeiliClient:
    """High-level Meilisearch client with convenience methods."""

    def __init__(
        self,
        host: str = "http://localhost:7700",
        api_key: Optional[str] = None,
        *,
        timeout: int = 10,
        validate: bool = True,
    ) -> None:
        """
        Initialise the client.

        Args:
            host: Meilisearch server URL.
            api_key: Master or admin API key.
            timeout: HTTP request timeout in seconds.
            validate: If ``True``, perform a health check on init.
        """
        self._host = host.rstrip("/")
        self._client = meilisearch.Client(self._host, api_key, timeout=timeout)
        if validate:
            self._validate_connection()

    # -- connection ---------------------------------------------------------

    def _validate_connection(self) -> None:
        """Verify the server is reachable and healthy."""
        try:
            health = self._client.health()
            if health.get("status") != "available":
                raise ConnectionError(f"Unexpected health status: {health}")
            logger.info("Connected to Meilisearch at %s", self._host)
        except MeilisearchError as exc:
            raise ConnectionError(f"Cannot reach Meilisearch: {exc}") from exc

    @property
    def raw(self) -> meilisearch.Client:
        """Return the underlying SDK client for advanced usage."""
        return self._client

    # -----------------------------------------------------------------------
    # Index Management
    # -----------------------------------------------------------------------

    def create_index(
        self, uid: str, primary_key: Optional[str] = None
    ) -> dict[str, Any]:
        """Create an index and wait for the task to complete."""
        task = self._client.create_index(uid, {"primaryKey": primary_key})
        return self.wait_for_task(task.task_uid)

    def delete_index(self, uid: str) -> dict[str, Any]:
        """Delete an index and wait for the task to complete."""
        task = self._client.delete_index(uid)
        return self.wait_for_task(task.task_uid)

    def list_indexes(self) -> list[dict[str, Any]]:
        """Return metadata for every index on the instance."""
        result = self._client.get_indexes()
        return [
            {"uid": idx.uid, "primaryKey": idx.primary_key, "createdAt": idx.created_at}
            for idx in (result["results"] if isinstance(result, dict) else result)
        ]

    def get_index_stats(self, uid: str) -> dict[str, Any]:
        """Return stats (document count, field distribution, etc.) for an index."""
        index = self._client.index(uid)
        return index.get_stats()

    def update_index_settings(
        self, uid: str, settings: dict[str, Any]
    ) -> dict[str, Any]:
        """Apply partial settings to an index and wait for completion."""
        index = self._client.index(uid)
        task = index.update_settings(settings)
        return self.wait_for_task(task.task_uid)

    def get_index_settings(self, uid: str) -> dict[str, Any]:
        """Get the current settings of an index."""
        index = self._client.index(uid)
        return index.get_settings()

    # -----------------------------------------------------------------------
    # Document Management
    # -----------------------------------------------------------------------

    def add_documents(
        self,
        uid: str,
        documents: list[dict[str, Any]],
        primary_key: Optional[str] = None,
    ) -> dict[str, Any]:
        """Add or replace documents and wait for the task to complete."""
        index = self._client.index(uid)
        task = index.add_documents(documents, primary_key)
        return self.wait_for_task(task.task_uid)

    def update_documents(
        self,
        uid: str,
        documents: list[dict[str, Any]],
        primary_key: Optional[str] = None,
    ) -> dict[str, Any]:
        """Partially update documents (merge fields) and wait."""
        index = self._client.index(uid)
        task = index.update_documents(documents, primary_key)
        return self.wait_for_task(task.task_uid)

    def delete_documents(self, uid: str, ids: list[str | int]) -> dict[str, Any]:
        """Delete documents by primary-key values and wait."""
        index = self._client.index(uid)
        task = index.delete_documents(ids)
        return self.wait_for_task(task.task_uid)

    def get_document(self, uid: str, document_id: str | int) -> dict[str, Any]:
        """Fetch a single document by its primary key."""
        index = self._client.index(uid)
        return index.get_document(document_id)

    def get_documents(
        self,
        uid: str,
        *,
        offset: int = 0,
        limit: int = 20,
        fields: Optional[list[str]] = None,
    ) -> dict[str, Any]:
        """Fetch a paginated list of documents."""
        index = self._client.index(uid)
        params: dict[str, Any] = {"offset": offset, "limit": limit}
        if fields:
            params["fields"] = fields
        return index.get_documents(params)

    def bulk_import(
        self,
        uid: str,
        documents: list[dict[str, Any]],
        *,
        batch_size: int = 1000,
        primary_key: Optional[str] = None,
    ) -> list[dict[str, Any]]:
        """
        Import a large list of documents in batches.

        Returns a list of completed task results – one per batch.
        """
        index = self._client.index(uid)
        results: list[dict[str, Any]] = []
        total = len(documents)

        for start in range(0, total, batch_size):
            batch = documents[start : start + batch_size]
            task = index.add_documents(batch, primary_key)
            result = self.wait_for_task(task.task_uid)
            results.append(result)
            logger.info(
                "Imported batch %d–%d / %d",
                start + 1,
                min(start + batch_size, total),
                total,
            )

        return results

    # -----------------------------------------------------------------------
    # Search
    # -----------------------------------------------------------------------

    def search(
        self,
        uid: str,
        query: str,
        *,
        limit: int = 20,
        offset: int = 0,
        filter: Optional[str | list[str]] = None,  # noqa: A002
        facets: Optional[list[str]] = None,
        sort: Optional[list[str]] = None,
        attributes_to_retrieve: Optional[list[str]] = None,
        attributes_to_highlight: Optional[list[str]] = None,
        page: Optional[int] = None,
        hits_per_page: Optional[int] = None,
    ) -> dict[str, Any]:
        """
        Execute a search query with optional filters, facets, and sorting.

        Args:
            uid: Index identifier.
            query: Full-text query string.
            limit: Maximum number of hits (offset-based pagination).
            offset: Starting offset (offset-based pagination).
            filter: Filter expression string or array.
            facets: Attributes to compute facet counts for.
            sort: Sort rules, e.g. ``["price:asc"]``.
            attributes_to_retrieve: Fields to include in each hit.
            attributes_to_highlight: Fields to highlight with match tags.
            page: Page number for page-based pagination (1-indexed).
            hits_per_page: Hits per page for page-based pagination.

        Returns:
            Raw search response dict (hits, query, processingTimeMs, …).
        """
        index = self._client.index(uid)
        params: dict[str, Any] = {}

        if page is not None:
            params["page"] = page
            if hits_per_page is not None:
                params["hitsPerPage"] = hits_per_page
        else:
            params["limit"] = limit
            params["offset"] = offset

        if filter:
            params["filter"] = filter
        if facets:
            params["facets"] = facets
        if sort:
            params["sort"] = sort
        if attributes_to_retrieve:
            params["attributesToRetrieve"] = attributes_to_retrieve
        if attributes_to_highlight:
            params["attributesToHighlight"] = attributes_to_highlight

        return index.search(query, params)

    def geo_search(
        self,
        uid: str,
        query: str,
        *,
        lat: float,
        lng: float,
        radius_m: Optional[int] = None,
        sort_by_distance: bool = True,
        limit: int = 20,
    ) -> dict[str, Any]:
        """
        Search with geo-radius filtering and optional distance sorting.

        Args:
            uid: Index identifier.
            query: Full-text query.
            lat: Latitude of the reference point.
            lng: Longitude of the reference point.
            radius_m: Maximum distance in metres. ``None`` disables the filter.
            sort_by_distance: Sort results by distance ascending.
            limit: Maximum number of hits.
        """
        params: dict[str, Any] = {"limit": limit}

        if radius_m is not None:
            params["filter"] = f"_geoRadius({lat}, {lng}, {radius_m})"
        if sort_by_distance:
            params["sort"] = [f"_geoPoint({lat}, {lng}):asc"]

        index = self._client.index(uid)
        return index.search(query, params)

    def hybrid_search(
        self,
        uid: str,
        query: str,
        *,
        semantic_ratio: float = 0.5,
        embedder: str = "default",
        limit: int = 20,
    ) -> dict[str, Any]:
        """
        Perform hybrid keyword + semantic search (Meilisearch v1.3+).

        Args:
            uid: Index identifier.
            query: Natural-language query.
            semantic_ratio: 0.0 = pure keyword, 1.0 = pure semantic.
            embedder: Name of the configured embedder.
            limit: Maximum hits.
        """
        index = self._client.index(uid)
        params: dict[str, Any] = {
            "limit": limit,
            "hybrid": {
                "semanticRatio": semantic_ratio,
                "embedder": embedder,
            },
        }
        return index.search(query, params)

    def multi_search(self, queries: list[dict[str, Any]]) -> dict[str, Any]:
        """
        Execute multiple search queries in a single HTTP request.

        Args:
            queries: List of dicts, each with ``indexUid``, ``q``, and
                     optional search parameters.

        Returns:
            Combined results keyed by index.
        """
        return self._client.multi_search(queries)

    # -----------------------------------------------------------------------
    # Task Monitoring
    # -----------------------------------------------------------------------

    def wait_for_task(
        self,
        task_uid: int,
        *,
        timeout_ms: int = 30_000,
        interval_ms: int = 250,
    ) -> dict[str, Any]:
        """
        Poll until a task reaches a terminal state.

        Raises:
            TaskFailedError: If the task fails.
            TimeoutError: If the timeout is exceeded.
        """
        deadline = time.monotonic() + timeout_ms / 1000
        while True:
            task = self._client.get_task(task_uid)
            status = task.get("status") if isinstance(task, dict) else getattr(task, "status", None)

            if status in ("succeeded", "failed", "canceled"):
                task_dict = task if isinstance(task, dict) else vars(task)
                if status == "failed":
                    error = task_dict.get("error", {})
                    raise TaskFailedError(task_uid, error)
                return task_dict

            if time.monotonic() > deadline:
                raise TimeoutError(
                    f"Task {task_uid} did not complete within {timeout_ms}ms"
                )
            time.sleep(interval_ms / 1000)

    def get_task(self, task_uid: int) -> TaskInfo:
        """Retrieve details for a single task."""
        raw = self._client.get_task(task_uid)
        t = raw if isinstance(raw, dict) else vars(raw)
        return TaskInfo(
            uid=t["uid"],
            status=t["status"],
            type=t["type"],
            index_uid=t.get("indexUid"),
            error=t.get("error"),
            duration=t.get("duration"),
            enqueued_at=t.get("enqueuedAt"),
            started_at=t.get("startedAt"),
            finished_at=t.get("finishedAt"),
            details=t.get("details", {}),
        )

    def list_tasks(
        self,
        *,
        index_uids: Optional[list[str]] = None,
        statuses: Optional[list[str]] = None,
        types: Optional[list[str]] = None,
        limit: int = 20,
    ) -> list[TaskInfo]:
        """List recent tasks with optional filters."""
        params: dict[str, Any] = {"limit": limit}
        if index_uids:
            params["indexUids"] = index_uids
        if statuses:
            params["statuses"] = statuses
        if types:
            params["types"] = types

        result = self._client.get_tasks(params)
        raw_list = result.get("results", []) if isinstance(result, dict) else result
        return [
            TaskInfo(
                uid=t.get("uid", t.get("taskUid", 0)),
                status=t.get("status", "unknown"),
                type=t.get("type", "unknown"),
                index_uid=t.get("indexUid"),
                error=t.get("error"),
                duration=t.get("duration"),
            )
            for t in raw_list
        ]

    # -----------------------------------------------------------------------
    # Backup / Dumps
    # -----------------------------------------------------------------------

    def create_dump(self) -> dict[str, Any]:
        """Trigger a full database dump and wait for it to finish."""
        task = self._client.create_dump()
        uid = task.task_uid if hasattr(task, "task_uid") else task.get("taskUid", task.get("uid"))
        return self.wait_for_task(uid, timeout_ms=300_000)

    # -----------------------------------------------------------------------
    # Tenant Tokens
    # -----------------------------------------------------------------------

    def generate_tenant_token(
        self,
        api_key_uid: str,
        search_rules: dict[str, Any] | list[str],
        *,
        expires_at: Optional[str] = None,
        api_key: Optional[str] = None,
    ) -> str:
        """
        Generate a tenant token (JWT) embedding search-rule restrictions.

        Args:
            api_key_uid: UID of the parent API key (from ``/keys``).
            search_rules: Per-index filter rules or list of allowed indexes.
            expires_at: ISO-8601 expiry timestamp.
            api_key: Signing key. Defaults to the client's key.

        Returns:
            Signed JWT string.
        """
        return self._client.generate_tenant_token(
            api_key_uid=api_key_uid,
            search_rules=search_rules,
            expires_at=expires_at,
            api_key=api_key,
        )


# ---------------------------------------------------------------------------
# CLI Interface
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="search-client",
        description="Meilisearch CLI – common operations from the command line.",
    )
    parser.add_argument(
        "--host",
        default="http://localhost:7700",
        help="Meilisearch URL (default: %(default)s)",
    )
    parser.add_argument("--api-key", default=None, help="API key")
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable debug logging"
    )

    sub = parser.add_subparsers(dest="command", required=True)

    # -- search -------------------------------------------------------------
    sp_search = sub.add_parser("search", help="Run a search query")
    sp_search.add_argument("index", help="Index UID")
    sp_search.add_argument("query", help="Search query")
    sp_search.add_argument("--limit", type=int, default=10)
    sp_search.add_argument("--filter", default=None)
    sp_search.add_argument("--sort", nargs="*", default=None)
    sp_search.add_argument("--facets", nargs="*", default=None)

    # -- import -------------------------------------------------------------
    sp_import = sub.add_parser("import", help="Import documents from a JSON file")
    sp_import.add_argument("index", help="Index UID")
    sp_import.add_argument("file", help="Path to JSON file (array of objects)")
    sp_import.add_argument("--batch-size", type=int, default=1000)
    sp_import.add_argument("--primary-key", default=None)

    # -- backup -------------------------------------------------------------
    sub.add_parser("backup", help="Create a full database dump")

    # -- indexes ------------------------------------------------------------
    sub.add_parser("indexes", help="List all indexes")

    # -- settings -----------------------------------------------------------
    sp_settings = sub.add_parser(
        "settings", help="Get or apply index settings"
    )
    sp_settings.add_argument("index", help="Index UID")
    sp_settings.add_argument(
        "--apply",
        default=None,
        help="Path to a JSON settings file to apply",
    )

    # -- tasks --------------------------------------------------------------
    sp_tasks = sub.add_parser("tasks", help="List recent tasks")
    sp_tasks.add_argument("--limit", type=int, default=10)

    return parser


def _run_cli(argv: Sequence[str] | None = None) -> None:
    parser = _build_parser()
    args = parser.parse_args(argv)

    configure_logging(logging.DEBUG if args.verbose else logging.INFO)

    client = MeiliClient(args.host, args.api_key, validate=True)

    if args.command == "search":
        results = client.search(
            args.index,
            args.query,
            limit=args.limit,
            filter=args.filter,
            sort=args.sort,
            facets=args.facets,
        )
        print(json.dumps(results, indent=2, default=str))

    elif args.command == "import":
        data = json.loads(Path(args.file).read_text())
        if not isinstance(data, list):
            logger.error("JSON file must contain an array of objects.")
            sys.exit(1)
        results = client.bulk_import(
            args.index, data, batch_size=args.batch_size, primary_key=args.primary_key
        )
        print(f"Imported {len(data)} documents in {len(results)} batch(es).")

    elif args.command == "backup":
        result = client.create_dump()
        print(f"Dump completed. Task: {json.dumps(result, indent=2, default=str)}")

    elif args.command == "indexes":
        indexes = client.list_indexes()
        print(json.dumps(indexes, indent=2, default=str))

    elif args.command == "settings":
        if args.apply:
            settings = json.loads(Path(args.apply).read_text())
            result = client.update_index_settings(args.index, settings)
            print(f"Settings applied. Task: {json.dumps(result, indent=2, default=str)}")
        else:
            settings = client.get_index_settings(args.index)
            print(json.dumps(settings, indent=2, default=str))

    elif args.command == "tasks":
        tasks = client.list_tasks(limit=args.limit)
        for t in tasks:
            print(f"[{t.status:>10}] #{t.uid}  {t.type}  index={t.index_uid}")


# ---------------------------------------------------------------------------
# Entry Point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    _run_cli()
