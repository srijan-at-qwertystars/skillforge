"""
Django model template for pgvector.

Provides:
  - Document model with pgvector VectorField
  - Custom manager with similarity search methods
  - HNSW index configuration

Setup:
    1. pip install django pgvector
    2. Add 'pgvector.django' to INSTALLED_APPS (if using pgvector >= 0.3.0)
    3. Copy this file to your Django app's models.py
    4. Run: python manage.py makemigrations && python manage.py migrate

Usage:
    from myapp.models import Document

    # Insert
    Document.objects.create(
        title="Example",
        content="Some text",
        embedding=[0.1, 0.2, ...],  # 1536-dim vector
    )

    # Similarity search
    results = Document.vectors.search_similar([0.1, 0.2, ...], limit=10)

    # Filtered search
    results = Document.vectors.search_similar(
        [0.1, 0.2, ...], limit=10, source="web"
    )

    # Hybrid search (vector + full-text)
    results = Document.vectors.search_hybrid(
        query_vector=[0.1, ...],
        query_text="postgresql vector search",
        limit=10,
    )

Prerequisites:
    pip install django pgvector psycopg[binary]
"""

from django.db import models, connection
from django.contrib.postgres.indexes import GinIndex
from django.contrib.postgres.search import (
    SearchVector, SearchQuery, SearchRank, SearchVectorField
)

from pgvector.django import (
    VectorField, HalfVectorField,
    HnswIndex, IvfflatIndex,
    CosineDistance, L2Distance, MaxInnerProduct,
)


# =============================================================================
# Custom Manager with Vector Search Methods
# =============================================================================

class VectorSearchManager(models.Manager):
    """Manager adding vector similarity search capabilities."""

    def search_similar(
        self,
        query_vector: list[float],
        limit: int = 10,
        distance: str = "cosine",
        ef_search: int = 100,
        **filters,
    ):
        """Find nearest neighbors by vector similarity.

        Args:
            query_vector: Query embedding (list of floats)
            limit: Maximum number of results
            distance: Distance function ("cosine", "l2", or "ip")
            ef_search: HNSW search parameter (higher = better recall)
            **filters: Additional Django ORM filters (e.g., source="web")

        Returns:
            QuerySet annotated with 'distance' field, ordered by distance
        """
        distance_fns = {
            "cosine": CosineDistance,
            "l2": L2Distance,
            "ip": MaxInnerProduct,
        }
        dist_fn = distance_fns[distance]

        # Set ef_search for this query
        with connection.cursor() as cursor:
            cursor.execute(f"SET LOCAL hnsw.ef_search = {ef_search}")

        qs = self.get_queryset()
        if filters:
            qs = qs.filter(**filters)

        return (
            qs.annotate(distance=dist_fn("embedding", query_vector))
            .order_by("distance")[:limit]
        )

    def search_by_threshold(
        self,
        query_vector: list[float],
        max_distance: float = 0.3,
        limit: int = 100,
        **filters,
    ):
        """Find all items within a distance threshold.

        Args:
            query_vector: Query embedding
            max_distance: Maximum cosine distance (0 = identical, 1 = orthogonal)
            limit: Maximum results
            **filters: Additional Django ORM filters

        Returns:
            QuerySet of items within distance threshold
        """
        qs = self.get_queryset()
        if filters:
            qs = qs.filter(**filters)

        return (
            qs.annotate(distance=CosineDistance("embedding", query_vector))
            .filter(distance__lt=max_distance)
            .order_by("distance")[:limit]
        )

    def search_hybrid(
        self,
        query_vector: list[float],
        query_text: str,
        limit: int = 10,
        vector_weight: float = 0.7,
        text_weight: float = 0.3,
        **filters,
    ):
        """Hybrid search combining vector similarity and full-text search.

        Uses score blending (not RRF). For RRF, use the SQL function in schema.sql.

        Args:
            query_vector: Query embedding
            query_text: Full-text search query string
            limit: Maximum results
            vector_weight: Weight for vector similarity score (0-1)
            text_weight: Weight for text search score (0-1)
            **filters: Additional Django ORM filters

        Returns:
            QuerySet annotated with combined_score, vector distance, and text rank
        """
        search_query = SearchQuery(query_text, search_type="websearch")

        qs = self.get_queryset()
        if filters:
            qs = qs.filter(**filters)

        return (
            qs.filter(search_vector=search_query)
            .annotate(
                vector_distance=CosineDistance("embedding", query_vector),
                text_rank=SearchRank("search_vector", search_query),
            )
            .annotate(
                combined_score=(
                    vector_weight * (1 - models.F("vector_distance")) +
                    text_weight * models.F("text_rank")
                )
            )
            .order_by("-combined_score")[:limit]
        )

    def find_duplicates(
        self,
        threshold: float = 0.05,
        limit: int = 100,
    ):
        """Find near-duplicate documents by embedding similarity.

        Args:
            threshold: Maximum cosine distance to consider duplicate
            limit: Maximum pairs to return

        Returns:
            List of (doc_a, doc_b, distance) tuples
        """
        from django.db import connection as conn

        with conn.cursor() as cursor:
            cursor.execute("""
                SELECT a.id, b.id, a.embedding <=> b.embedding AS distance
                FROM documents a
                CROSS JOIN LATERAL (
                    SELECT id, embedding FROM documents
                    WHERE id > a.id
                    ORDER BY embedding <=> a.embedding
                    LIMIT 1
                ) b
                WHERE a.embedding <=> b.embedding < %s
                ORDER BY distance
                LIMIT %s
            """, [threshold, limit])
            rows = cursor.fetchall()

        doc_ids = set()
        for row in rows:
            doc_ids.add(row[0])
            doc_ids.add(row[1])
        docs = {d.id: d for d in self.filter(id__in=doc_ids)}

        return [(docs.get(r[0]), docs.get(r[1]), r[2]) for r in rows]


# =============================================================================
# Document Model
# =============================================================================

class Document(models.Model):
    """Document with vector embedding for similarity search."""

    title = models.CharField(max_length=500, blank=True, default="")
    content = models.TextField()
    source = models.CharField(max_length=500, blank=True, default="")
    metadata = models.JSONField(default=dict, blank=True)

    # Vector columns
    embedding = VectorField(dimensions=1536, null=True, blank=True)
    embedding_half = HalfVectorField(dimensions=1536, null=True, blank=True)

    # Full-text search (populated via trigger or signal)
    search_vector = SearchVectorField(null=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    # Managers
    objects = models.Manager()
    vectors = VectorSearchManager()

    class Meta:
        db_table = "documents"
        indexes = [
            # HNSW index on dense embedding
            HnswIndex(
                name="idx_doc_embedding_hnsw",
                fields=["embedding"],
                m=16,
                ef_construction=128,
                opclasses=["vector_cosine_ops"],
            ),
            # HNSW on half-precision embedding
            HnswIndex(
                name="idx_doc_embedding_half_hnsw",
                fields=["embedding_half"],
                m=16,
                ef_construction=128,
                opclasses=["halfvec_cosine_ops"],
            ),
            # Full-text search
            GinIndex(
                name="idx_doc_search_vector",
                fields=["search_vector"],
            ),
            # Metadata JSONB
            GinIndex(
                name="idx_doc_metadata",
                fields=["metadata"],
                opclasses=["jsonb_path_ops"],
            ),
        ]

    def __str__(self):
        return f"Document({self.id}: {self.title or self.content[:50]})"

    def save(self, *args, **kwargs):
        """Auto-sync halfvec from embedding on save."""
        if self.embedding is not None and self.embedding_half is None:
            self.embedding_half = self.embedding
        super().save(*args, **kwargs)


# =============================================================================
# Signal: Update search_vector on save
# =============================================================================

from django.db.models.signals import post_save
from django.dispatch import receiver


@receiver(post_save, sender=Document)
def update_search_vector(sender, instance, **kwargs):
    """Update the full-text search vector after save."""
    sender.objects.filter(pk=instance.pk).update(
        search_vector=(
            SearchVector("title", weight="A") +
            SearchVector("content", weight="B")
        )
    )


# =============================================================================
# Migration Helper
# =============================================================================

# Add to your migration to create the pgvector extension:
#
# from django.db import migrations
#
# class Migration(migrations.Migration):
#     dependencies = [...]
#
#     operations = [
#         migrations.RunSQL(
#             "CREATE EXTENSION IF NOT EXISTS vector;",
#             reverse_sql="DROP EXTENSION IF EXISTS vector;"
#         ),
#         ...
#     ]
