"""
SQLAlchemy 2.0 model template for pgvector.

Provides:
  - Document model with vector, halfvec, and sparsevec columns
  - Query helpers for nearest neighbor, filtered, and hybrid search
  - Session and engine setup

Usage:
    from sqlalchemy_model import Document, get_engine, get_session

    engine = get_engine("postgresql+psycopg://user:pass@localhost/vectordb")
    session = get_session(engine)

    # Insert
    doc = Document(title="Example", content="Some text", embedding=[0.1, 0.2, ...])
    session.add(doc)
    session.commit()

    # Search
    results = Document.search_similar(session, query_vector, limit=10)

Prerequisites:
    pip install 'sqlalchemy>=2.0' 'psycopg[binary]' pgvector
"""

import os
from datetime import datetime
from typing import Optional

from sqlalchemy import (
    BigInteger, DateTime, Index, String, Text, create_engine, event, func, select, text
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import (
    DeclarativeBase, Mapped, Session, mapped_column, sessionmaker
)

from pgvector.sqlalchemy import Vector, HalfVector, SparseVector, BIT
from pgvector.sqlalchemy import cosine_distance, l2_distance, inner_product


# =============================================================================
# Base
# =============================================================================

class Base(DeclarativeBase):
    pass


# =============================================================================
# Document Model
# =============================================================================

class Document(Base):
    __tablename__ = "documents"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    title: Mapped[Optional[str]] = mapped_column(String(500), nullable=True)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    source: Mapped[Optional[str]] = mapped_column(String(500), nullable=True)
    metadata_: Mapped[Optional[dict]] = mapped_column("metadata", JSONB, default=dict)

    # Vector columns
    embedding: Mapped[Optional[list]] = mapped_column(Vector(1536), nullable=True)
    embedding_half: Mapped[Optional[list]] = mapped_column(HalfVector(1536), nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    __table_args__ = (
        Index(
            "idx_documents_hnsw",
            "embedding",
            postgresql_using="hnsw",
            postgresql_with={"m": 16, "ef_construction": 128},
            postgresql_ops={"embedding": "vector_cosine_ops"},
        ),
        Index(
            "idx_documents_hnsw_half",
            "embedding_half",
            postgresql_using="hnsw",
            postgresql_with={"m": 16, "ef_construction": 128},
            postgresql_ops={"embedding_half": "halfvec_cosine_ops"},
        ),
    )

    def __repr__(self) -> str:
        return f"<Document(id={self.id}, title={self.title!r})>"

    # =========================================================================
    # Query Helpers
    # =========================================================================

    @classmethod
    def search_similar(
        cls,
        session: Session,
        query_vector: list[float],
        limit: int = 10,
        distance_fn: str = "cosine",
        ef_search: int = 100,
    ) -> list[tuple["Document", float]]:
        """Find nearest neighbors by vector similarity.

        Args:
            session: SQLAlchemy session
            query_vector: Query embedding
            limit: Max results
            distance_fn: "cosine", "l2", or "ip"
            ef_search: HNSW search parameter (higher = better recall, slower)

        Returns:
            List of (Document, distance) tuples ordered by distance
        """
        dist_fns = {
            "cosine": cosine_distance,
            "l2": l2_distance,
            "ip": inner_product,
        }
        dist = dist_fns[distance_fn](cls.embedding, query_vector)

        session.execute(text(f"SET LOCAL hnsw.ef_search = {ef_search}"))

        stmt = (
            select(cls, dist.label("distance"))
            .order_by(dist)
            .limit(limit)
        )
        results = session.execute(stmt).all()
        return [(row.Document, row.distance) for row in results]

    @classmethod
    def search_filtered(
        cls,
        session: Session,
        query_vector: list[float],
        filters: dict,
        limit: int = 10,
    ) -> list[tuple["Document", float]]:
        """Search with metadata JSONB filter.

        Args:
            session: SQLAlchemy session
            query_vector: Query embedding
            filters: JSONB containment filter (e.g., {"source": "web"})
            limit: Max results

        Returns:
            List of (Document, distance) tuples
        """
        dist = cosine_distance(cls.embedding, query_vector)
        stmt = (
            select(cls, dist.label("distance"))
            .where(cls.metadata_.op("@>")(filters))
            .order_by(dist)
            .limit(limit)
        )
        results = session.execute(stmt).all()
        return [(row.Document, row.distance) for row in results]

    @classmethod
    def search_hybrid(
        cls,
        session: Session,
        query_vector: list[float],
        query_text: str,
        limit: int = 10,
        vector_weight: float = 1.0,
        text_weight: float = 1.0,
        rrf_k: int = 60,
    ) -> list[dict]:
        """Hybrid search using the hybrid_search SQL function.

        Requires the hybrid_search function from schema.sql to be installed.

        Args:
            session: SQLAlchemy session
            query_vector: Query embedding
            query_text: Full-text search query
            limit: Max results

        Returns:
            List of dicts with id, title, content, rrf_score
        """
        stmt = text("""
            SELECT * FROM hybrid_search(
                :embedding::vector(1536),
                :query_text,
                :match_count,
                :rrf_k,
                :vector_weight,
                :text_weight
            )
        """)
        vec_str = "[" + ",".join(str(x) for x in query_vector) + "]"
        results = session.execute(stmt, {
            "embedding": vec_str,
            "query_text": query_text,
            "match_count": limit,
            "rrf_k": rrf_k,
            "vector_weight": vector_weight,
            "text_weight": text_weight,
        }).fetchall()

        return [
            {
                "id": r[0], "title": r[1], "content": r[2],
                "metadata": r[3], "rrf_score": r[4],
                "vector_rank": r[5], "text_rank": r[6],
            }
            for r in results
        ]

    @classmethod
    def bulk_insert(cls, session: Session, items: list[dict]) -> int:
        """Bulk insert documents with embeddings.

        Args:
            session: SQLAlchemy session
            items: List of dicts with keys matching column names.
                   Required: content, embedding
                   Optional: title, source, metadata

        Returns:
            Number of inserted rows
        """
        docs = [cls(**item) for item in items]
        session.add_all(docs)
        session.flush()
        return len(docs)


# =============================================================================
# Engine & Session Factory
# =============================================================================

def get_engine(url: str | None = None, **kwargs):
    """Create SQLAlchemy engine with pgvector-friendly defaults."""
    url = url or os.environ.get("DATABASE_URL", "postgresql+psycopg://postgres:postgres@localhost/vectordb")
    return create_engine(
        url,
        pool_size=5,
        max_overflow=10,
        pool_pre_ping=True,
        **kwargs,
    )


def get_session(engine) -> Session:
    """Create a new session."""
    return sessionmaker(bind=engine)()


def init_db(engine):
    """Create all tables and install pgvector extension."""
    with engine.connect() as conn:
        conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))
        conn.commit()
    Base.metadata.create_all(engine)


# =============================================================================
# Example Usage
# =============================================================================

if __name__ == "__main__":
    engine = get_engine()
    init_db(engine)

    with get_session(engine) as session:
        # Insert example
        doc = Document(
            title="Example Document",
            content="PostgreSQL with pgvector enables vector similarity search.",
            embedding=[0.1] * 1536,
            metadata_={"source": "example"},
        )
        session.add(doc)
        session.commit()

        # Search example
        query = [0.1] * 1536
        results = Document.search_similar(session, query, limit=5)
        for doc, dist in results:
            print(f"  {doc.id}: {doc.title} (distance={dist:.4f})")
