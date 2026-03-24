# Feature Flag Platform Comparison

> **Last reviewed:** 2025 · Pricing, features, and SDK support change frequently.
> Always verify details against each vendor's official documentation before making purchasing decisions.

---

## Table of Contents

1. [Overview](#overview)
2. [Platform Profiles](#platform-profiles)
   - [LaunchDarkly](#launchdarkly)
   - [Unleash](#unleash)
   - [Flagsmith](#flagsmith)
   - [PostHog](#posthog)
   - [Flipt](#flipt)
   - [CloudBees Feature Management](#cloudbees-feature-management)
   - [Split](#split)
3. [Comparison Tables](#comparison-tables)
   - [Feature Matrix](#feature-matrix)
   - [Pricing Comparison](#pricing-comparison)
   - [SDK Coverage](#sdk-coverage)
   - [Compliance and Security](#compliance-and-security)
4. [Architecture Patterns](#architecture-patterns)
   - [Evaluation Models](#evaluation-models)
   - [Data Flow and Latency](#data-flow-and-latency)
5. [Integration Ecosystem](#integration-ecosystem)
6. [Decision Guide](#decision-guide)
   - [By Organization Type](#by-organization-type)
   - [By Technical Requirements](#by-technical-requirements)
   - [Migration Considerations](#migration-considerations)
7. [Appendix](#appendix)

---

## Overview

Feature flag platforms vary significantly in architecture, pricing philosophy, and target audience. This document provides a factual, side-by-side comparison of seven major platforms to help engineering teams make informed decisions.

**Platforms compared:**

| Platform | Founded | License Model | Primary Audience |
|----------|---------|---------------|------------------|
| LaunchDarkly | 2014 | Proprietary (SaaS) | Mid-market to Enterprise |
| Unleash | 2015 | Open-source (Apache 2.0) + Commercial | Startups to Enterprise |
| Flagsmith | 2019 | Open-source (BSD 3-Clause) + Commercial | Startups to Mid-market |
| PostHog | 2020 | Open-source (MIT) + Commercial | Product teams, PLG companies |
| Flipt | 2019 | Open-source (GPL 3.0) | Engineering-led orgs, self-hosters |
| CloudBees | 2010 (flags ~2017) | Proprietary (SaaS/On-prem) | Enterprise, CI/CD-heavy orgs |
| Split | 2015 | Proprietary (SaaS) | Data-driven engineering orgs |

---

## Platform Profiles

### LaunchDarkly

#### Overview and Architecture

LaunchDarkly is the category-defining feature flag platform and the most mature commercial offering. It uses a streaming architecture where flag changes are pushed to SDKs in near real-time via server-sent events (SSE). Server-side SDKs maintain an in-memory cache of all flag rules and evaluate locally — no network call is required per evaluation. Client-side SDKs receive pre-evaluated flag values from LaunchDarkly's edge infrastructure.

**Architecture highlights:**
- Streaming-first delivery model (SSE) with polling fallback
- Server-side SDKs evaluate locally using a local rule cache
- Client-side SDKs receive evaluated values from LD's evaluation service
- Relay Proxy available for air-gapped or high-availability deployments
- Multi-environment support with environment-scoped flag configurations

#### Pricing Model

| Tier | Price | Includes |
|------|-------|----------|
| Developer | Free | 1 project, 2 environments, up to 1,000 MAUs (client-side) |
| Foundation | ~$12/seat/month (billed annually) | Unlimited flags, custom roles, SSO |
| Enterprise | Custom pricing | Advanced security, SLA, dedicated support, unlimited MAUs |

- Server-side evaluations are unlimited on all tiers
- Client-side pricing is based on Monthly Active Users (MAUs)
- Experimentation is an add-on with additional per-event pricing

#### SDK Support

- **Server-side:** Go, Java, .NET, Node.js, Python, Ruby, PHP, Rust, C/C++, Haskell, Lua, Erlang
- **Client-side:** JavaScript, React, React Native, iOS (Swift/ObjC), Android (Java/Kotlin), Flutter, Electron
- **Edge:** Cloudflare Workers, Vercel Edge, AWS Lambda@Edge (via Edge SDKs)
- **Community SDKs:** Available for additional languages

#### Targeting Rules and Segmentation

- Boolean, string, number, and JSON flag variations
- User-level, segment-level, and rule-based targeting
- Percentage rollouts with consistent bucketing (user key hashing)
- Multi-variate flags (up to 100+ variations)
- Reusable segments with AND/OR/NOT conditions
- Contextual targeting (users, devices, organizations — "contexts" model)
- Prerequisite flags (flag A depends on flag B)
- Scheduled flag changes (flag lifecycles)

#### Audit Logs and Compliance

- Full audit log of all flag changes, including who changed what and when
- Audit log export via API and integrations (Datadog, Splunk, etc.)
- Flag change history with diff view
- Approval workflows for production changes
- SOC 2 Type II certified
- HIPAA BAA available on Enterprise plans
- GDPR compliant — data processing agreements available
- FedRAMP authorization in progress (verify current status)

#### RBAC

- Custom roles with fine-grained permissions (per-project, per-environment, per-flag)
- Built-in roles: Reader, Writer, Admin, Owner
- Policy-based access using a custom policy language
- SSO/SAML integration (Enterprise)
- SCIM provisioning for user management

#### Edge Evaluation

- Relay Proxy for self-hosted edge evaluation
- Edge SDKs for Cloudflare Workers, Vercel Edge Functions
- Server-side SDKs already evaluate locally (effectively "edge" by design)

#### OpenFeature Compatibility

- Official OpenFeature provider for Go, Java, .NET, JavaScript, Python, PHP
- Active contributor to the OpenFeature specification

#### Self-Hosted Options

- **Not available as a fully self-hosted product**
- Relay Proxy can be self-hosted to reduce external dependencies
- Relay Proxy supports Redis, DynamoDB, and Consul as backing stores

#### Unique Differentiators

- Most mature platform with the broadest SDK coverage
- Streaming architecture delivers sub-second flag propagation
- Contexts model enables targeting beyond users (devices, orgs, services)
- Experimentation and A/B testing as a built-in feature
- Largest ecosystem of integrations (Jira, Slack, Datadog, Terraform, etc.)
- Code references: scans repos to show where flags are used in code

---

### Unleash

#### Overview and Architecture

Unleash is an open-source feature flag platform with a server-client architecture. The Unleash server stores flag configurations and exposes them via a REST API. SDKs periodically poll the server and evaluate flags locally. Unleash offers both a self-hosted open-source version and a managed cloud offering (Unleash Cloud).

**Architecture highlights:**
- Polling-based delivery (configurable interval, typically 15s)
- Server-side SDKs evaluate locally using a cached rule set
- Frontend/client-side SDKs use a front-end API or the Unleash Proxy
- Unleash Edge (Rust-based) replaces the legacy Unleash Proxy for edge evaluation
- PostgreSQL is the only supported backing store

#### Pricing Model

| Tier | Price | Includes |
|------|-------|----------|
| Open Source | Free (self-hosted) | Core features, 1 environment, no RBAC |
| Pro | ~$80/month base | 5 seats included, additional seats ~$15/seat, up to 3 environments |
| Enterprise | Custom pricing | Unlimited environments, advanced RBAC, SSO, change requests |

- No MAU-based pricing — pricing is seat-based
- Self-hosted open-source version has no seat limits
- Enterprise features (SSO, RBAC, audit logs) require paid plans

#### SDK Support

- **Server-side:** Go, Java, .NET, Node.js, Python, Ruby, PHP, Rust
- **Client-side:** JavaScript (browser), React, Vue, Svelte, Angular, Next.js
- **Mobile:** iOS (Swift), Android (Kotlin/Java), React Native, Flutter
- **Community SDKs:** Dart, Elixir, Laravel, Django, and others

#### Targeting Rules and Segmentation

- Activation strategies: Standard, Gradual Rollout, UserIDs, IPs, Hostnames
- Custom strategies for domain-specific targeting logic
- Segments for reusable audience definitions
- Constraints with operators (IN, NOT_IN, STR_CONTAINS, NUM_GT, etc.)
- Variants for A/B testing and multivariate flags
- Strategy ordering and fallback chains
- Dependent feature flags (Enterprise)

#### Audit Logs and Compliance

- Event log tracks all flag changes with user attribution
- Event log accessible via API
- Change request workflows (Enterprise)
- SOC 2 Type II (Unleash Cloud)
- GDPR compliant
- HIPAA — verify current availability with Unleash

#### RBAC

- Open-source: Basic admin/viewer roles
- Pro: Project-level roles
- Enterprise: Custom roles, environment-level permissions, group-based access
- SSO/SAML (Enterprise)
- SCIM provisioning (Enterprise)

#### Edge Evaluation

- **Unleash Edge:** Rust-based edge component that caches flag configs and evaluates locally
- Replaces legacy Node.js-based Unleash Proxy
- Can run as a sidecar, at the CDN edge, or in each data center
- Sub-millisecond evaluation latency

#### OpenFeature Compatibility

- Official OpenFeature providers for Go, Java, .NET, JavaScript, Python
- Active participant in OpenFeature community

#### Self-Hosted Options

- **Fully self-hostable** — open-source server available under Apache 2.0
- Docker images and Helm charts provided
- Requires PostgreSQL
- Enterprise features require a commercial license even when self-hosted

#### Unique Differentiators

- Open-source core with a strong community
- Custom activation strategies for domain-specific logic
- Unleash Edge (Rust) is one of the fastest edge evaluation components available
- No MAU-based pricing — cost-effective for high-traffic consumer apps
- Impressions data for tracking flag evaluations
- Feature flag lifecycle management (mark flags as stale, archive, etc.)

---

### Flagsmith

#### Overview and Architecture

Flagsmith is an open-source feature management platform that combines feature flags with remote configuration. It offers both a SaaS product and a self-hosted option. Flagsmith evaluates flags server-side by default, but also supports local evaluation mode in server-side SDKs for reduced latency.

**Architecture highlights:**
- REST API-based flag delivery (polling or real-time via SSE)
- Local evaluation mode for server-side SDKs (caches rules, evaluates locally)
- Remote evaluation mode for client-side SDKs (server evaluates per request)
- Built on Django/Python with PostgreSQL
- Edge proxy available for high-performance edge evaluation

#### Pricing Model

| Tier | Price | Includes |
|------|-------|----------|
| Open Source | Free (self-hosted) | All core features, unlimited flags |
| Free Cloud | Free | Up to 50,000 requests/month, 1 project |
| Startup | ~$45/month | Up to 1M requests/month, 5 team members |
| Scale-Up | ~$200/month+ | Higher request limits, priority support |
| Enterprise | Custom pricing | SLA, SSO, dedicated infrastructure |

- Pricing based on API requests, not seats or MAUs (on lower tiers)
- Self-hosted open-source version is fully featured

#### SDK Support

- **Server-side:** Go, Java, .NET, Node.js, Python, Ruby, PHP, Rust, Elixir
- **Client-side:** JavaScript, React, Next.js, Angular, Vue
- **Mobile:** iOS (Swift), Android (Kotlin/Java), React Native, Flutter
- **REST API:** Direct HTTP calls for unsupported languages

#### Targeting Rules and Segmentation

- Boolean flags and multivariate flags (string/int/float/boolean)
- Remote configuration (key-value pairs attached to flags)
- Identity-based targeting with traits (user attributes)
- Segment rules with AND/OR conditions on traits
- Percentage rollouts using identity hashing
- Multi-variate flag values with percentage distribution
- Change requests and approval workflows (Enterprise)

#### Audit Logs and Compliance

- Audit log of all changes (available on paid plans and self-hosted)
- Webhook notifications for flag changes
- SOC 2 Type II (Flagsmith Cloud)
- GDPR compliant
- HIPAA — available on Enterprise with BAA

#### RBAC

- Organization-level and project-level roles
- Built-in roles: Admin, Member with project-level overrides
- Environment-level permissions (manage flags, approve changes)
- Custom roles available on higher tiers
- SSO/SAML (Enterprise)
- Group-based permission management

#### Edge Evaluation

- Edge Proxy for self-hosted edge evaluation
- Local evaluation mode in server-side SDKs functions as edge evaluation
- Caches flag configurations locally with periodic refresh

#### OpenFeature Compatibility

- Official OpenFeature providers for Go, Java, .NET, JavaScript, Python
- REST API allows custom provider implementation for any language

#### Self-Hosted Options

- **Fully self-hostable** — open-source under BSD 3-Clause
- Docker images and Helm charts available
- Supports PostgreSQL and optionally Redis for caching
- All features available in self-hosted (no feature gating on OSS)
- InfluxDB integration for analytics (optional)

#### Unique Differentiators

- Combined feature flags + remote configuration in one platform
- BSD 3-Clause license (permissive, no copyleft concerns)
- All features available in the open-source self-hosted version
- Request-based pricing avoids seat and MAU cost scaling
- Trait-based identity system for rich user modeling
- Multi-project and multi-organization support

---

### PostHog

#### Overview and Architecture

PostHog is an all-in-one product analytics platform that includes feature flags as one of several integrated tools (analytics, session replay, A/B testing, surveys). Feature flags are tightly coupled with PostHog's analytics pipeline, enabling feature-aware analytics out of the box.

**Architecture highlights:**
- Feature flags are evaluated server-side via PostHog's API
- Local evaluation mode for server-side SDKs (downloads flag definitions, evaluates locally)
- Client-side SDKs call PostHog's /decide endpoint for flag evaluation
- Built on ClickHouse (analytics) and PostgreSQL (metadata)
- Flags are integrated with PostHog's event pipeline

#### Pricing Model

| Tier | Price | Includes |
|------|-------|----------|
| Free | $0 | Up to 1M flag requests/month |
| Paid | Usage-based, starting ~$0/month | First 1M requests free, then ~$0.0001/request |
| Enterprise | Custom pricing | SSO, advanced permissions, SLA |

- Feature flags pricing is purely usage-based (requests)
- Analytics, session replay, and surveys are priced separately
- Self-hosted is free with no request limits
- No per-seat charges for feature flags

#### SDK Support

- **Server-side:** Go, Java, Node.js, Python, Ruby, PHP, Rust, Elixir
- **Client-side:** JavaScript, React, Next.js, Vue, Angular, Astro, Svelte, Nuxt
- **Mobile:** iOS (Swift), Android (Kotlin/Java), React Native, Flutter
- **Other:** API-based evaluation for any language

#### Targeting Rules and Segmentation

- Boolean and multivariate flags
- User property-based targeting
- Group-based targeting (companies, teams)
- Percentage rollouts with consistent bucketing
- Cohort-based targeting (leveraging PostHog's analytics cohorts)
- Geographic and property-based conditions
- Multi-variate feature flags for A/B/n testing
- Payloads (arbitrary JSON attached to flag variants)
- Early access feature management

#### Audit Logs and Compliance

- Activity log for flag changes
- Integrated with PostHog's broader audit capabilities
- SOC 2 Type II certified
- GDPR compliant with EU hosting available
- HIPAA BAA available on Enterprise/self-hosted
- Data residency options (US, EU)

#### RBAC

- Organization and project-level access
- Role-based access: Admin, Member
- Feature flag-specific permissions on higher tiers
- SSO/SAML (Enterprise/paid add-on)

#### Edge Evaluation

- Local evaluation in server-side SDKs
- No dedicated edge proxy component
- Client-side SDKs rely on PostHog's API endpoint

#### OpenFeature Compatibility

- OpenFeature provider available for some languages
- Verify current coverage on PostHog's docs

#### Self-Hosted Options

- **Fully self-hostable** — open-source under MIT license
- Docker Compose and Helm chart deployments
- Requires ClickHouse, PostgreSQL, Redis, Kafka
- Significant infrastructure requirements for self-hosting
- All features available in self-hosted version

#### Unique Differentiators

- Feature flags integrated with product analytics, session replay, and A/B testing
- Cohort targeting powered by analytics data (target users who did X action)
- No separate tool needed for experimentation — built into the same platform
- Generous free tier (1M requests/month)
- MIT license for self-hosted
- Early access feature management (let users opt-in to features)
- Feature flag usage automatically appears in analytics dashboards

---

### Flipt

#### Overview and Architecture

Flipt is an open-source feature flag solution designed for simplicity and self-hosting. It is a single binary with no external dependencies (embedded database or optional PostgreSQL/MySQL/CockroachDB). Flipt evaluates flags server-side and exposes a gRPC and REST API.

**Architecture highlights:**
- Single Go binary with embedded SQLite (or external DB)
- gRPC-first with REST gateway
- Server-side evaluation via API calls
- Client-side evaluation via Flipt's evaluation API
- Git-based flag storage (GitOps-native) as alternative to database
- Declarative flag definitions in YAML/JSON

#### Pricing Model

| Tier | Price | Includes |
|------|-------|----------|
| Open Source | Free | All core features, unlimited everything |
| Flipt Cloud | Free tier + paid plans | Managed hosting, team collaboration |
| Flipt Enterprise | Custom pricing | SSO, audit logs, advanced RBAC |

- No per-seat, per-MAU, or per-request pricing on self-hosted
- Flipt Cloud pricing is evolving — check current plans
- Enterprise features available via commercial license

#### SDK Support

- **Server-side:** Go, Java, .NET, Node.js, Python, Ruby, PHP, Rust, Dart
- **Client-side:** JavaScript/TypeScript, React
- **Mobile:** Flutter (via Dart SDK), React Native (via JS SDK)
- **gRPC:** Native gRPC clients for any language with gRPC support
- **REST API:** Direct HTTP for any language

#### Targeting Rules and Segmentation

- Boolean flags and variant flags
- Segment-based targeting with constraint rules
- Entity-level targeting with properties
- Percentage-based distribution across variants
- Match types: ALL (AND), ANY (OR) for constraints
- Constraint operators: eq, neq, lt, lte, gt, gte, prefix, suffix, contains, is_one_of, is_not_one_of
- Namespace-based flag organization

#### Audit Logs and Compliance

- Audit events stored in the database
- Webhook notifications for flag changes
- SOC 2 — verify current status with Flipt
- GDPR-friendly — all data stays in your infrastructure (self-hosted)
- HIPAA — self-hosted deployment enables compliance (your responsibility)

#### RBAC

- Basic authentication with static tokens
- OIDC/OAuth2 authentication support
- Namespace-level access control
- Advanced RBAC available in Enterprise
- No SCIM provisioning currently

#### Edge Evaluation

- No dedicated edge component
- Single binary can be deployed at the edge (small footprint)
- Client-side evaluation SDKs can cache and evaluate locally

#### OpenFeature Compatibility

- Official OpenFeature provider for Go, Java, .NET, JavaScript, Python, PHP
- Strong commitment to OpenFeature standard

#### Self-Hosted Options

- **Designed for self-hosting** — this is the primary deployment model
- Single binary, minimal dependencies
- Docker, Kubernetes (Helm), and bare-metal deployments
- GitOps-native: flag definitions can live in a Git repository
- Supports SQLite (embedded), PostgreSQL, MySQL, CockroachDB, libSQL

#### Unique Differentiators

- GitOps-native: store flag definitions in Git alongside application code
- Single binary with zero external dependencies (SQLite mode)
- gRPC-first design for high-performance evaluation
- Declarative flag definitions (YAML/JSON) — infrastructure-as-code friendly
- No vendor lock-in by design
- Namespaces for multi-tenancy and flag organization
- OCI-compatible bundle support for distributing flag configurations

---

### CloudBees Feature Management

#### Overview and Architecture

CloudBees Feature Management (formerly Rollout.io, acquired by CloudBees in 2019) is an enterprise-grade feature flag platform. It integrates into the broader CloudBees DevOps platform and is designed for large-scale enterprise deployments with strict compliance requirements.

**Architecture highlights:**
- SDKs cache flag configurations locally and evaluate client-side
- Dashboard manages flag definitions, targeting rules, and configurations
- Designed for tight integration with CI/CD pipelines (Jenkins, CloudBees CI)
- Supports multi-environment and multi-application configurations
- Flag configurations are pushed to SDKs

#### Pricing Model

| Tier | Price | Includes |
|------|-------|----------|
| Free | Limited free tier | Basic flags, limited users |
| Teams | Custom pricing | Team collaboration features |
| Enterprise | Custom pricing | Full RBAC, SSO, compliance, dedicated support |

- Contact CloudBees for current pricing structure
- Typically bundled with broader CloudBees platform licensing
- Enterprise pricing often negotiated as part of a platform deal

#### SDK Support

- **Server-side:** Go, Java, .NET, Node.js, Python, Ruby, PHP
- **Client-side:** JavaScript
- **Mobile:** iOS (Swift/ObjC), Android (Java/Kotlin), React Native, Xamarin
- **Edge Workers:** Cloudflare Workers support

#### Targeting Rules and Segmentation

- Boolean and multivariate flags
- Custom property-based targeting
- Percentage-based rollouts
- Target groups and segments
- Scheduled flag changes
- Configuration rules with priority ordering
- Kill switch for emergency flag disabling
- Flag dependencies

#### Audit Logs and Compliance

- Comprehensive audit trail of all changes
- Integration with enterprise SIEM tools
- SOC 2 Type II certified
- HIPAA compliant (with BAA)
- GDPR compliant
- FedRAMP — verify current authorization status

#### RBAC

- Enterprise-grade role-based access control
- Custom roles and permissions
- Environment-level access restrictions
- SSO/SAML integration
- Integration with enterprise identity providers (Okta, Azure AD, etc.)
- Approval workflows for production changes

#### Edge Evaluation

- SDKs evaluate locally after initial configuration download
- Cloudflare Workers integration for edge evaluation
- Designed for low-latency evaluation in distributed systems

#### OpenFeature Compatibility

- OpenFeature provider available — verify current language support
- CloudBees has indicated support for OpenFeature standards

#### Self-Hosted Options

- On-premises deployment available for Enterprise customers
- Hybrid deployment models supported
- Air-gapped environment support
- Integrates with existing enterprise infrastructure

#### Unique Differentiators

- Deep CI/CD integration (Jenkins, CloudBees CI/CD)
- Enterprise pedigree with established compliance certifications
- Part of a broader DevOps platform (not just feature flags)
- Strong mobile SDK support (including Xamarin)
- Designed for regulated industries (financial services, healthcare)
- Kill switch pattern for rapid emergency response

---

### Split

#### Overview and Architecture

Split (now part of Harness, acquired in 2023) is a feature delivery platform that emphasizes data-driven feature management. Split differentiates itself through its focus on feature impact measurement — connecting flag changes to metrics to answer "did this feature improve things?"

**Architecture highlights:**
- Streaming architecture (SSE) for real-time flag updates
- Server-side SDKs evaluate locally after receiving flag definitions
- Client-side SDKs can evaluate locally or remotely
- Tight integration with metrics pipelines for impact analysis
- Event tracking built into the SDK for automatic metric collection

#### Pricing Model

| Tier | Price | Includes |
|------|-------|----------|
| Free (Developer) | $0 | Up to 10 seats, limited feature flags |
| Team | ~$33/seat/month | Full feature flags, integrations |
| Business/Enterprise | Custom pricing | SSO, RBAC, premium support, SLA |

- Now part of Harness — pricing may be bundled with Harness platform
- Verify current standalone pricing availability
- No MAU-based component — seat-based pricing

#### SDK Support

- **Server-side:** Go, Java, .NET, Node.js, Python, Ruby, PHP
- **Client-side:** JavaScript (browser), React, Angular, Redux
- **Mobile:** iOS (Swift/ObjC), Android (Java/Kotlin), React Native, Flutter
- **Other:** REST API for unsupported platforms

#### Targeting Rules and Segmentation

- Boolean, string, and multivariate treatments
- Attribute-based targeting rules
- Percentage-based traffic allocation
- Segment definitions for reusable audience groups
- Individual targeting overrides
- Default rules and kill switches
- Dynamic configuration (key-value config attached to treatments)
- Dependencies between feature flags

#### Audit Logs and Compliance

- Full audit log with user attribution
- Change history with before/after comparisons
- Integration with observability platforms
- SOC 2 Type II certified
- HIPAA compliant with BAA
- GDPR compliant
- Now inherits Harness compliance certifications

#### RBAC

- Workspace-level and environment-level permissions
- Custom roles (Business/Enterprise)
- SSO/SAML integration
- Admin, Manager, and custom role definitions
- API key management with scoped permissions

#### Edge Evaluation

- Server-side SDKs evaluate locally (effectively edge)
- Streaming updates ensure near-instant propagation
- Split Proxy available for self-hosted relay/caching
- Split Evaluator for languages without native SDK support

#### OpenFeature Compatibility

- OpenFeature providers for Go, Java, .NET, JavaScript, Python
- Active OpenFeature contributor

#### Self-Hosted Options

- **Not available as a fully self-hosted product**
- Split Proxy can be self-hosted for relay and caching
- Split Synchronizer for offline/air-gapped environments
- Now part of Harness — self-hosted Harness may include feature flags

#### Unique Differentiators

- Feature impact measurement: automatic statistical analysis of feature impact on metrics
- Data-driven rollouts: connect flag changes to business and engineering metrics
- Impression tracking for understanding who saw what
- Traffic type concept for managing flags across different entity types
- Integration with Harness platform for end-to-end software delivery
- Attribution — automatically attribute metric changes to specific feature releases

---

## Comparison Tables

### Feature Matrix

| Feature | LaunchDarkly | Unleash | Flagsmith | PostHog | Flipt | CloudBees | Split |
|---------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| Boolean flags | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Multivariate flags | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Remote configuration | ✅ | ❌ | ✅ | ✅ (payloads) | ❌ | ✅ | ✅ |
| Percentage rollouts | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| User targeting | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Segment targeting | ✅ | ✅ | ✅ | ✅ (cohorts) | ✅ | ✅ | ✅ |
| Prerequisite flags | ✅ | ✅ (Enterprise) | ❌ | ❌ | ❌ | ✅ | ✅ |
| Scheduled changes | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |
| A/B testing | ✅ (add-on) | ✅ (variants) | ✅ (variants) | ✅ (native) | ❌ | ✅ | ✅ (native) |
| Experimentation | ✅ (add-on) | ❌ | ❌ | ✅ (native) | ❌ | ❌ | ✅ (native) |
| Approval workflows | ✅ | ✅ (Enterprise) | ✅ (Enterprise) | ❌ | ❌ | ✅ | ✅ |
| Audit logs | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Custom RBAC | ✅ | ✅ (Enterprise) | ✅ | Limited | Limited | ✅ | ✅ |
| SSO/SAML | ✅ | ✅ (Enterprise) | ✅ (Enterprise) | ✅ (paid) | ✅ (Enterprise) | ✅ | ✅ |
| SCIM provisioning | ✅ | ✅ (Enterprise) | ❌ | ❌ | ❌ | ✅ | ✅ |
| Streaming updates | ✅ (SSE) | ❌ (polling) | ✅ (SSE) | ❌ (polling) | ❌ (polling) | ✅ | ✅ (SSE) |
| Local evaluation | ✅ | ✅ | ✅ | ✅ | Via API | ✅ | ✅ |
| Edge proxy/component | ✅ (Relay) | ✅ (Edge) | ✅ (Edge Proxy) | ❌ | ❌ | ✅ | ✅ (Proxy) |
| GitOps support | ❌ | ❌ | ❌ | ❌ | ✅ (native) | ❌ | ❌ |
| Terraform provider | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ | ✅ |
| Code references | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Flag lifecycle mgmt | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Webhooks | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| OpenFeature support | ✅ | ✅ | ✅ | Partial | ✅ | Partial | ✅ |
| Analytics integration | ✅ | ✅ (impressions) | ✅ | ✅ (native) | ❌ | ✅ | ✅ (native) |

### Pricing Comparison

> **⚠️ Pricing changes frequently.** The figures below are approximate and based on publicly available information. Always verify with vendors.

| Dimension | LaunchDarkly | Unleash | Flagsmith | PostHog | Flipt | CloudBees | Split |
|-----------|-------------|---------|-----------|---------|-------|-----------|-------|
| **Free tier** | Yes (limited) | Yes (OSS) | Yes (OSS + Cloud) | Yes (1M req) | Yes (OSS) | Limited | Yes (10 seats) |
| **Pricing model** | Per-seat + MAU | Per-seat | Per-request | Per-request | Free / Custom | Custom | Per-seat |
| **~10 devs estimate** | ~$120/mo + MAU | ~$155/mo | ~$45-200/mo | Usage-based | Free (self-host) | Custom | ~$330/mo |
| **MAU/request costs** | Yes (client-side) | No | Yes (API calls) | Yes (requests) | No | Varies | No |
| **Self-hosted free** | No | Yes (OSS) | Yes (OSS) | Yes (OSS) | Yes (OSS) | No | No |
| **Enterprise starting** | ~$10K+/yr | Custom | Custom | Custom | Custom | Custom | Custom |

**Cost scaling characteristics:**

| Scenario | Cheapest Options | Most Expensive |
|----------|-----------------|----------------|
| Small team (< 5 devs) | Flipt, PostHog Free, Unleash OSS | LaunchDarkly, Split |
| High client-side traffic (10M+ MAU) | Unleash, Flipt, Split | LaunchDarkly, PostHog |
| Large team (50+ devs) | Flipt, Flagsmith, Unleash OSS | LaunchDarkly, Split |
| Enterprise compliance needs | Unleash Enterprise, Flagsmith Enterprise | LaunchDarkly Enterprise |

### SDK Coverage

| Language / Platform | LaunchDarkly | Unleash | Flagsmith | PostHog | Flipt | CloudBees | Split |
|--------------------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Server-Side** | | | | | | | |
| Go | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Java | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| .NET / C# | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| Node.js | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Python | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Ruby | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| PHP | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Rust | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Elixir | ❌ | Community | ✅ | ✅ | ❌ | ❌ | ❌ |
| C/C++ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Client-Side** | | | | | | | |
| JavaScript | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| React | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| Vue | ❌ | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ |
| Angular | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| Next.js | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **Mobile** | | | | | | | |
| iOS (Swift) | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| Android (Kotlin) | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| React Native | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| Flutter | ✅ | ✅ | ✅ | ✅ | ✅ (Dart) | ❌ | ✅ |
| **Edge** | | | | | | | |
| Cloudflare Workers | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |
| Vercel Edge | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Lambda@Edge | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

### Compliance and Security

| Certification / Feature | LaunchDarkly | Unleash | Flagsmith | PostHog | Flipt | CloudBees | Split |
|------------------------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| SOC 2 Type II | ✅ | ✅ (Cloud) | ✅ (Cloud) | ✅ | Verify | ✅ | ✅ |
| HIPAA (BAA available) | ✅ (Enterprise) | Verify | ✅ (Enterprise) | ✅ (Enterprise) | N/A (self-host) | ✅ | ✅ |
| GDPR compliant | ✅ | ✅ | ✅ | ✅ | ✅ (self-host) | ✅ | ✅ |
| EU data residency | ✅ | ✅ (Cloud) | ✅ | ✅ | ✅ (self-host) | ✅ | ✅ |
| FedRAMP | In progress | ❌ | ❌ | ❌ | ❌ | Verify | ❌ |
| SSO/SAML | ✅ | Enterprise | Enterprise | Paid | Enterprise | ✅ | ✅ |
| SCIM | ✅ | Enterprise | ❌ | ❌ | ❌ | ✅ | ✅ |
| Encryption at rest | ✅ | ✅ | ✅ | ✅ | Your infra | ✅ | ✅ |
| Encryption in transit | ✅ (TLS) | ✅ (TLS) | ✅ (TLS) | ✅ (TLS) | ✅ (TLS) | ✅ (TLS) | ✅ (TLS) |
| Audit log retention | Configurable | Plan-dependent | Plan-dependent | Plan-dependent | Your infra | Configurable | Plan-dependent |
| Approval workflows | ✅ | Enterprise | Enterprise | ❌ | ❌ | ✅ | ✅ |
| IP allowlisting | ✅ | ❌ | ❌ | ❌ | Your infra | ✅ | ✅ |
| Air-gapped deployment | ✅ (Relay) | ✅ (self-host) | ✅ (self-host) | ✅ (self-host) | ✅ (self-host) | ✅ | ✅ (Synchronizer) |
| Self-hosted option | Relay only | ✅ | ✅ | ✅ | ✅ | ✅ (Enterprise) | Proxy only |

---

## Architecture Patterns

### Evaluation Models

Understanding where flag evaluation happens is critical for latency, privacy, and offline support.

| Model | How It Works | Latency | Privacy | Platforms |
|-------|-------------|---------|---------|-----------|
| **Local (server-side)** | SDK downloads all rules, evaluates in-process | Sub-ms | High (data stays local) | All platforms (server SDKs) |
| **Remote (API call)** | SDK calls platform API per evaluation | 10-100ms | Lower (context sent to API) | Flagsmith, PostHog, Flipt (client-side) |
| **Streaming** | Rules streamed to SDK, evaluated locally | Sub-ms eval, sub-second updates | High | LaunchDarkly, Split |
| **Polling** | SDK periodically fetches rules | Sub-ms eval, 10-60s update delay | High | Unleash, PostHog, Flipt |
| **Edge proxy** | Proxy caches rules at edge, evaluates locally | Low (< 5ms) | High | LaunchDarkly Relay, Unleash Edge, Flagsmith Edge Proxy |
| **GitOps** | Flags defined in Git, loaded at deploy time | Sub-ms | Highest | Flipt |

### Data Flow and Latency

```
┌─────────────────────────────────────────────────────────────────┐
│                    Evaluation Latency Spectrum                   │
│                                                                  │
│  Fastest ◄──────────────────────────────────────────► Slowest    │
│                                                                  │
│  GitOps      Local      Edge       Streaming    Polling  Remote  │
│  (deploy)    (in-proc)  (proxy)    (push)       (pull)   (API)   │
│  ~0ms        <1ms       <5ms       <1s update   15-60s   50ms+   │
│                                                                  │
│  Flipt       All        LD Relay   LD, Split    Unleash  Flagsmith│
│              (server    Unleash    Flagsmith    PostHog  (client)  │
│              SDKs)      Edge                    Flipt    PostHog   │
│                         Flagsmith                       (client)  │
│                         Edge Proxy                                │
└─────────────────────────────────────────────────────────────────┘
```

---

## Integration Ecosystem

| Integration | LaunchDarkly | Unleash | Flagsmith | PostHog | Flipt | CloudBees | Split |
|-------------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| Slack | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| Jira | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ |
| Datadog | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Terraform | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ | ✅ |
| GitHub Actions | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| VS Code | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |
| Segment | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ |
| Amplitude | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| New Relic | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Jenkins | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |

---

## Decision Guide

### By Organization Type

#### Startup / Small Team (< 10 engineers)

**Recommended:** PostHog, Flipt, or Unleash OSS

| Option | Why | Watch Out For |
|--------|-----|---------------|
| **PostHog** | All-in-one (analytics + flags + experiments), generous free tier, no infra to manage | Heavier than a flags-only tool, analytics lock-in |
| **Flipt** | Zero cost, zero dependencies, GitOps-native, simple mental model | No built-in analytics, limited collaboration features |
| **Unleash OSS** | Full-featured self-hosted, strong community, no seat limits | Requires PostgreSQL, no RBAC on OSS tier |

**Avoid:** LaunchDarkly (cost scales quickly), CloudBees (enterprise-oriented), Split (seat-based pricing adds up).

#### Mid-Size Engineering Org (10–100 engineers)

**Recommended:** LaunchDarkly, Unleash Pro/Enterprise, or Flagsmith

| Option | Why | Watch Out For |
|--------|-----|---------------|
| **LaunchDarkly** | Best-in-class UX, streaming updates, deep integrations | Per-seat + MAU pricing can get expensive |
| **Unleash Pro** | No MAU charges, good feature set, open-source escape hatch | Polling (not streaming), fewer integrations than LD |
| **Flagsmith** | Request-based pricing, self-hosted option, remote config included | Smaller community, fewer enterprise references |

**Key considerations:** Evaluate total cost based on your team size AND client-side traffic. LaunchDarkly is the premium choice but costs more. Unleash is the best value if you don't need streaming.

#### Enterprise with Compliance Needs

**Recommended:** LaunchDarkly Enterprise, CloudBees, or Split (Harness)

| Option | Why | Watch Out For |
|--------|-----|---------------|
| **LaunchDarkly** | Most compliance certs, approval workflows, SCIM, Relay Proxy for air-gap | Highest cost at scale |
| **CloudBees** | Deep CI/CD integration, on-prem deployment, enterprise pedigree | Less modern UX, smaller feature flag community |
| **Split (Harness)** | Impact analysis, backed by Harness platform, strong compliance | Harness acquisition may change product direction |
| **Unleash Enterprise** | Self-hosted with enterprise features, GDPR-friendly | Verify HIPAA/FedRAMP status |

**Key considerations:** Prioritize approval workflows, audit log retention, SSO/SCIM, and self-hosted or air-gapped deployment options. Verify FedRAMP and HIPAA certifications directly with vendors.

#### Open-Source-First Organization

**Recommended:** Flipt, Unleash OSS, or Flagsmith OSS

| Option | Why | Watch Out For |
|--------|-----|---------------|
| **Flipt** | GPL 3.0, GitOps-native, single binary, community-driven | GPL may conflict with some corporate policies |
| **Unleash OSS** | Apache 2.0, most feature-rich OSS offering, strong community | Enterprise features (RBAC, SSO) require paid license |
| **Flagsmith OSS** | BSD 3-Clause, all features included in OSS, permissive license | Smaller community than Unleash |
| **PostHog** | MIT license, comprehensive platform (not just flags) | Heavy infrastructure requirements for self-hosting |

**License comparison:**

| Platform | License | Copyleft | Commercial Features Gated |
|----------|---------|----------|--------------------------|
| Flipt | GPL 3.0 | Yes | Enterprise (SSO, RBAC) |
| Unleash | Apache 2.0 | No | Yes (RBAC, SSO, change requests) |
| Flagsmith | BSD 3-Clause | No | No (all features in OSS) |
| PostHog | MIT | No | No (all features in OSS) |

#### Product-Led Growth Company

**Recommended:** PostHog or LaunchDarkly

| Option | Why | Watch Out For |
|--------|-----|---------------|
| **PostHog** | Flags + analytics + experiments in one tool, cohort-based targeting, early access management | Less sophisticated flag management than dedicated tools |
| **LaunchDarkly** | Contexts model for multi-entity targeting, experimentation add-on, code references | Experimentation is an add-on cost, MAU pricing scales with growth |
| **Split** | Native impact measurement, attribute metric changes to features | Harness platform direction, seat-based pricing |

**Key considerations:** PLG companies need tight integration between feature flags and product analytics. PostHog offers this natively. LaunchDarkly and Split require integrations but offer deeper flag management.

### By Technical Requirements

| Requirement | Best Options | Why |
|------------|-------------|-----|
| Sub-second flag propagation | LaunchDarkly, Split | Streaming (SSE) architecture |
| Air-gapped / on-prem | Flipt, Unleash, Flagsmith, PostHog | Fully self-hosted open-source |
| GitOps / IaC workflow | Flipt | Native Git backend, YAML definitions |
| Minimum infrastructure | Flipt | Single binary, embedded SQLite |
| High client-side traffic (low cost) | Unleash, Flipt, Split | No MAU-based pricing |
| Integrated experimentation | PostHog, Split | Native A/B testing with stats engine |
| Maximum SDK coverage | LaunchDarkly | 25+ official SDKs |
| gRPC-first architecture | Flipt | Native gRPC with REST gateway |
| OpenFeature standard | Flipt, LaunchDarkly, Unleash | Strong OpenFeature commitment |

### Migration Considerations

When switching between platforms, consider these factors:

| Factor | Impact | Mitigation |
|--------|--------|------------|
| SDK swap | Medium — requires code changes at every flag evaluation | Use OpenFeature SDK as an abstraction layer |
| Flag definition migration | Low-Medium — most platforms support API-based flag creation | Script migration using platform APIs |
| Targeting rules | Medium — rule syntax differs between platforms | Document rules in a platform-agnostic format first |
| Segment definitions | Medium — segments may use different attribute formats | Normalize user attributes across platforms |
| Integrations | Low — most platforms integrate with common tools | Prioritize Terraform/API-based configuration |
| Team training | Medium — UIs and workflows differ significantly | Plan for 1-2 sprint learning curve |
| Audit history | High — historical audit logs are not portable | Export audit logs before migration |

**OpenFeature as a migration strategy:**

Using OpenFeature SDKs from the start provides a vendor-neutral abstraction layer. If you adopt OpenFeature, switching providers becomes a configuration change rather than a code change:

```
Application Code → OpenFeature SDK → Provider (pluggable) → Platform
                                         ↑
                                    Swap this layer
                                    to change vendors
```

---

## Appendix

### Glossary

| Term | Definition |
|------|-----------|
| **MAU** | Monthly Active Users — unique users who evaluate a flag in a given month |
| **SSE** | Server-Sent Events — one-way streaming protocol for real-time updates |
| **Local evaluation** | SDK evaluates flags in-process without network calls |
| **Remote evaluation** | SDK calls an external API to evaluate each flag |
| **Edge evaluation** | Flag evaluation happens at a CDN or proxy layer close to the user |
| **OpenFeature** | CNCF project defining a vendor-neutral API for feature flag evaluation |
| **Relay Proxy** | Self-hosted component that caches flag configs and serves them to SDKs |
| **GitOps** | Managing flag definitions as code in a Git repository |
| **SCIM** | System for Cross-domain Identity Management — automated user provisioning |
| **BAA** | Business Associate Agreement — required for HIPAA compliance |

### Further Reading

- [OpenFeature Specification](https://openfeature.dev/)
- [CNCF Feature Flag Landscape](https://landscape.cncf.io/)
- LaunchDarkly Docs: https://docs.launchdarkly.com
- Unleash Docs: https://docs.getunleash.io
- Flagsmith Docs: https://docs.flagsmith.com
- PostHog Docs: https://posthog.com/docs/feature-flags
- Flipt Docs: https://www.flipt.io/docs
- CloudBees Feature Management Docs: https://docs.cloudbees.com/docs/cloudbees-feature-management
- Split Docs: https://www.split.io/docs (now via Harness)

---

*This document is a point-in-time reference. Vendors frequently update pricing, features, and compliance certifications. Verify all claims with official vendor documentation before making purchasing or architectural decisions.*
