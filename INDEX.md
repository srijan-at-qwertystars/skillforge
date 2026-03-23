# SkillForge Index

| Category | Skill Name | Description |
|----------|-----------|-------------|
| docker | [dockerfile-best-practices](docker/dockerfile-best-practices/) | Multi-stage builds, layer optimization, security hardening, BuildKit features, and production Dockerfile patterns |
| git | [git-rebase-workflows](git/git-rebase-workflows/) | Interactive rebase, autosquash, conflict resolution, reflog recovery, and rebase-vs-merge decision guidance |
| postgres | [postgres-performance-tuning](postgres/postgres-performance-tuning/) | EXPLAIN ANALYZE interpretation, index strategies, query anti-patterns, postgresql.conf tuning, and PgBouncer pooling |
| testing | [pytest-patterns](testing/pytest-patterns/) | Fixtures, parametrize, mocking, conftest organization, plugins, async testing, and anti-patterns |
| networking | [http-caching](networking/http-caching/) | Cache-Control directives, ETags, CDN strategies, cache invalidation, service worker caching, and debugging |
| security | [jwt-authentication](security/jwt-authentication/) | Token structure, algorithm selection, refresh token rotation, key management, vulnerabilities, and implementation patterns |
| typescript | [typescript-strict-migration](typescript/typescript-strict-migration/) | Strict flag reference, incremental migration strategies, error fixes, narrowing patterns, and CI integration |
| devops | [github-actions-workflows](devops/github-actions-workflows/) | Workflow anatomy, reusable workflows, composite actions, matrix builds, caching, security, and OIDC |
| api | [graphql-schema-design](api/graphql-schema-design/) | Schema-first vs code-first, Relay pagination, error handling, federation, DataLoader, and authorization patterns |
| observability | [opentelemetry-instrumentation](observability/opentelemetry-instrumentation/) | OTel architecture, auto/manual instrumentation, Collector config, sampling, context propagation, and metrics API |
| rust | [rust-error-handling](rust/rust-error-handling/) | Result/Option, thiserror/anyhow, custom error types, conversion chains, async errors, and library vs app design |
| aws | [terraform-aws-patterns](aws/terraform-aws-patterns/) | Module design, S3 state management, VPC/ECS/Lambda/RDS patterns, lifecycle rules, IAM security, and CI/CD |
| kubernetes | [helm-chart-patterns](kubernetes/helm-chart-patterns/) | Chart structure, template functions, helpers, values design, dependencies, hooks, testing, and security |
| python | [python-async-concurrency](python/python-async-concurrency/) | asyncio fundamentals, TaskGroups, concurrency primitives, patterns, pytest-asyncio, and sync integration |
| databases | [redis-patterns](databases/redis-patterns/) | Data structures, caching strategies, distributed locks, rate limiting, Streams, Lua scripting, and cluster patterns |
| go | [go-concurrency-patterns](go/go-concurrency-patterns/) | Goroutines, channels, select, sync primitives, errgroup, worker pools, race detection, and graceful shutdown |
| web | [css-grid-flexbox](web/css-grid-flexbox/) | Grid vs Flexbox decision guide, layout recipes, subgrid, container queries, responsive patterns, and pitfalls |
| security | [oauth2-openid-connect](security/oauth2-openid-connect/) | OAuth 2.1 grant types, PKCE flow, OIDC, BFF pattern, token rotation, provider integration, and vulnerabilities |
| react | [react-server-components](react/react-server-components/) | Server vs client components, directives, server actions, streaming, caching, App Router patterns, and migration |
| databases | [sql-query-optimization](databases/sql-query-optimization/) | Execution plans, join strategies, subquery refactoring, sargable predicates, pagination, ORM N+1, and anti-patterns |
| devops | [nginx-configuration](devops/nginx-configuration/) | Reverse proxy, load balancing, SSL/TLS, location blocks, rate limiting, security hardening, and performance tuning |
| messaging | [kafka-event-streaming](messaging/kafka-event-streaming/) | Topic design, producer/consumer patterns, exactly-once semantics, Kafka Streams, Connect, and serialization |
| shell | [bash-scripting-patterns](shell/bash-scripting-patterns/) | Strict mode, parameter expansion, arrays, trap handlers, ShellCheck fixes, portability, and anti-patterns |
| monitoring | [prometheus-alerting](monitoring/prometheus-alerting/) | Metric types, PromQL patterns, alerting/recording rules, Alertmanager routing, service discovery, and USE/RED |
| architecture | [twelve-factor-app](architecture/twelve-factor-app/) | All 12 factors with modern cloud-native guidance, plus API-first, telemetry, and security additions |
| testing | [api-contract-testing](testing/api-contract-testing/) | Pact consumer-driven contracts, provider verification, Pact Broker, OpenAPI validation, and async contracts |
| python | [python-packaging](python/python-packaging/) | pyproject.toml, build backends, package managers, src layout, versioning, PyPI publishing, and OIDC trusted publishing |
| web | [web-accessibility-a11y](web/web-accessibility-a11y/) | WCAG 2.2, semantic HTML, ARIA patterns, keyboard navigation, color contrast, forms, and testing tools |
| networking | [grpc-protobuf](networking/grpc-protobuf/) | Protobuf schema design, gRPC streaming, error handling, interceptors, Buf CLI, load balancing, and testing |
| devops | [kubernetes-troubleshooting](devops/kubernetes-troubleshooting/) | Pod failures, networking/DNS diagnosis, resource pressure, RBAC debugging, kubectl power commands, and decision trees |
| databases | [database-migration-strategies](databases/database-migration-strategies/) | Migration tools, zero-downtime patterns, expand-contract, large table strategies, rollback, and CI/CD integration |
| security | [cors-configuration](security/cors-configuration/) | CORS headers, preflight requests, credentials, framework configs (Express/Django/Spring/Nginx), errors, and debugging |
| java | [spring-boot-patterns](java/spring-boot-patterns/) | REST controllers, Spring Data JPA, SecurityFilterChain, testing pyramid, Actuator, and Spring Boot 3.x patterns |
| web | [web-performance-optimization](web/web-performance-optimization/) | Core Web Vitals, code splitting, image/font optimization, resource hints, bundle analysis, and performance budgets |
| git | [git-hooks-automation](git/git-hooks-automation/) | Husky v9, lint-staged, pre-commit framework, commitlint, Conventional Commits, Lefthook, and team sharing |
| architecture | [event-driven-architecture](architecture/event-driven-architecture/) | Event sourcing, CQRS, saga patterns, outbox pattern, idempotent consumers, schema evolution, and error handling |
| ai | [llm-prompt-engineering](ai/llm-prompt-engineering/) | Chain-of-thought, few-shot, system prompts, structured output, tool calling, prompt chaining, and provider tips |
| networking | [websocket-patterns](networking/websocket-patterns/) | WebSocket protocol, server/client implementations, reconnection, heartbeat, scaling with Redis, and security |
| devops | [logging-structured](devops/logging-structured/) | JSON logging, log levels, correlation IDs, context propagation, library examples (pino/structlog/slog), and redaction |
| security | [container-security](security/container-security/) | Image scanning, supply chain security (SBOM/cosign), runtime hardening, seccomp/AppArmor, rootless, and Pod Security |
| typescript | [zod-validation](typescript/zod-validation/) | Schema primitives, transforms, refinements, type inference, error handling, and integrations (RHF/tRPC/Next.js) |
| databases | [mongodb-patterns](databases/mongodb-patterns/) | Schema design patterns, indexing strategies, aggregation pipeline, transactions, Mongoose, and sharding |
| testing | [playwright-e2e-testing](testing/playwright-e2e-testing/) | Locators, page object model, fixtures, network mocking, visual regression, auth, and CI/CD with sharding |
| api | [rest-api-design](api/rest-api-design/) | Resource naming, HTTP methods/status codes, RFC 9457 errors, pagination, versioning, rate limiting, and OpenAPI |
| devops | [systemd-service-management](devops/systemd-service-management/) | Unit files, service types, timers, socket activation, security hardening, journald, and resource limits |
| react | [react-state-management](react/react-state-management/) | Zustand, Jotai, TanStack Query, Redux Toolkit, XState, Context optimization, form state, and URL state |
| go | [go-api-patterns](go/go-api-patterns/) | net/http (Go 1.22+), chi/echo/gin, middleware, graceful shutdown, error handling, DI, and httptest |
| security | [secret-management](security/secret-management/) | Vault, AWS Secrets Manager, SOPS, secret scanning, Kubernetes secrets, rotation, and incident response |
| python | [python-type-hints](python/python-type-hints/) | Type annotations, TypeVar, Protocol, ParamSpec, TypeGuard, mypy/pyright config, and gradual typing strategy |
| aws | [aws-lambda-patterns](aws/aws-lambda-patterns/) | Handler patterns, Powertools, cold starts, event sources, SAM/CDK deployment, layers, and performance tuning |
| architecture | [microservices-patterns](architecture/microservices-patterns/) | Decomposition, API gateway, circuit breaker, service mesh, sagas, CQRS, observability, and deployment |
| testing | [load-testing-k6](testing/load-testing-k6/) | k6 script structure, scenarios, thresholds, checks, browser module, CI integration, and performance testing patterns |
| web | [tailwind-css-patterns](web/tailwind-css-patterns/) | Tailwind v4 CSS-first config, utility patterns, dark mode, responsive design, CVA components, and plugin development |
| databases | [elasticsearch-patterns](databases/elasticsearch-patterns/) | Mappings, Query DSL, analyzers, aggregations, ILM hot-warm-cold, performance tuning, and data modeling |
| languages | [regex-patterns](languages/regex-patterns/) | Regex syntax, groups, lookaround, common patterns, catastrophic backtracking, ReDoS prevention, and language-specific syntax |
| python | [fastapi-patterns](python/fastapi-patterns/) | App structure, Pydantic v2, dependency injection, auth, WebSockets, async SQLAlchemy, testing, and deployment |
| devops | [ssh-configuration](devops/ssh-configuration/) | Key management, ssh_config, ProxyJump, tunneling, port forwarding, sshd hardening, certificate auth, and multiplexing |
| devops | [makefile-patterns](devops/makefile-patterns/) | GNU Make syntax, variables, pattern rules, functions, parallel execution, just/justfile, and project templates |
| architecture | [feature-flags](architecture/feature-flags/) | Flag types, lifecycle, OpenFeature, targeting rules, trunk-based development, operational flags, and cleanup |
| networking | [dns-configuration](networking/dns-configuration/) | Record types, email DNS (SPF/DKIM/DMARC), TTL strategy, DNSSEC, cloud DNS, debugging with dig, and migration |
| web | [vite-build-tools](web/vite-build-tools/) | Vite config, HMR, code splitting, plugins, library mode, SSR, environment variables, and Webpack migration |
| databases | [connection-pooling](databases/connection-pooling/) | Pool sizing, HikariCP, SQLAlchemy, node-pg, PgBouncer, PgCat, ProxySQL, serverless pooling, and monitoring |
| devops | [linux-debugging](devops/linux-debugging/) | strace, perf, eBPF/bpftrace, flamegraphs, valgrind, core dumps, network debugging, and USE method triage |
| databases | [prisma-orm](databases/prisma-orm/) | Schema design, relations, migrations, Prisma Client queries, transactions, extensions, type safety, and deployment |
| architecture | [rate-limiting-patterns](architecture/rate-limiting-patterns/) | Token bucket, sliding window, Redis distributed limiting, IETF headers, backoff/jitter, and gateway configs |
| git | [git-advanced-techniques](git/git-advanced-techniques/) | Bisect, worktrees, rerere, filter-repo, sparse checkout, subtrees, reflog, internals, and patch workflows |
| react | [nextjs-patterns](react/nextjs-patterns/) | App Router, Server/Client Components, Server Actions, caching, middleware, metadata, parallel routes, and deployment |
| architecture | [caching-strategies](architecture/caching-strategies/) | Cache-aside, write-through, invalidation strategies, stampede prevention, multi-layer caching, and monitoring |
| devops | [ansible-automation](devops/ansible-automation/) | Playbooks, roles, collections, Jinja2, vault, inventory, Molecule testing, AWX/AAP, and performance tuning |
