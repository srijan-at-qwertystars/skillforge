# Review: tls-certificate-management
Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5
Issues: Non-standard description format. 501 lines (1 over limit, trivial).

Outstanding TLS certificate guide. Covers TLS 1.3 handshake (1-RTT, 0-RTT resumption), certificate chain/CA hierarchy, trust stores (Debian/RHEL), certificate types table (DV/OV/EV/wildcard/SAN/self-signed/internal CA), ACME protocol (RFC 8555, HTTP-01/DNS-01 challenges), certbot commands (nginx/standalone/DNS-cloudflare/wildcard/revoke), Let's Encrypt 2025 rate limits (verified: 300 new orders per 3 hours, 50 certs/registered domain/week), 6-day short-lived certificates via `shortlived` ACME profile (verified), ARI renewals, cert-manager (Kubernetes install, ClusterIssuer HTTP-01/DNS-01, Certificate resource, Ingress annotation, troubleshooting), OpenSSL commands (key gen RSA/ECDSA/Ed25519, CSR with SANs, self-signed, CA signing, inspect/verify), certificate format conversion (PEM/DER/PKCS#12/JKS), mTLS (client cert gen, nginx config, curl test, Istio PeerAuthentication), certificate rotation (automated renewal strategy, zero-downtime rotation, OCSP stapling, CRL), cloud providers (ACM, GCP Certificate Manager, Cloudflare Origin CA), web server TLS config (nginx/Apache/Caddy), TLS debugging (openssl s_client commands, common errors table, expiry monitoring script), internal PKI (step-ca, cfssl, Vault PKI), Certificate Transparency (CT logs, SCTs, crt.sh, Sunlight by 2026), and anti-patterns.
