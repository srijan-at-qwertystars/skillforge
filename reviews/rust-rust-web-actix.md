# Review: rust-web-actix
Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5
Issues: Non-standard description format.

Excellent Rust web development guide covering both Actix Web and Axum. Includes framework comparison table, Axum patterns (Router, State, handlers, nesting), Actix patterns (App, scopes, web::Data), routing (path/query params, route groups), request extraction (JSON validation, multipart, custom extractors), response types (IntoResponse, custom wrappers), middleware (Tower layers for Axum, Actix middleware, rate limiting), state management (Arc + with_state vs web::Data), database (SQLx pool/compile-time queries/transactions/migrations, SeaORM), authentication (JWT middleware, Argon2 password hashing), error handling (thiserror + IntoResponse/ResponseError), testing (Tower oneshot, TestRequest, repository mocking), deployment (multi-stage Dockerfile, graceful shutdown, musl static linking), performance (tokio multi_thread, concurrency limits), and anti-patterns.
