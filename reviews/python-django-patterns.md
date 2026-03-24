# Review: django-patterns

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:
- **CheckConstraint uses deprecated `check=` parameter (line 88):** Django 5.1 renamed `check` to `condition` in `CheckConstraint`. The skill brands itself as "Django 5.x" but uses the deprecated syntax `models.CheckConstraint(check=models.Q(price__gte=0), ...)`. Should be `condition=models.Q(price__gte=0)`. The `check` parameter is removed entirely in Django 6.0.
- **Minor:** `IsOwnerOrReadOnly` permission (line 329) uses `request.method in ("GET", "HEAD", "OPTIONS")` — the canonical DRF idiom is `request.method in permissions.SAFE_METHODS`.

Strengths:
- Excellent structure: thin SKILL.md body (496 lines) with deep-dive references, scripts, and assets
- Django 5.x features (`GeneratedField`, `db_default`, `show_facets`, async views) are accurately documented
- Strong negative triggers prevent false activation for Flask/FastAPI/SQLAlchemy
- ORM patterns (F, Q, Subquery, Exists, prefetch) are correct and production-ready
- Testing section with factory_boy + pytest + query count assertions is pragmatic
- Production deployment section covers all critical settings
- Scripts (setup, migration check, security audit) are well-documented and useful
