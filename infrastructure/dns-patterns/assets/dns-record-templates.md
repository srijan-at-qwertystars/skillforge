# DNS Record Templates for Common Services

Copy-paste ready DNS record templates. Replace values in `<angle brackets>`.

---

## Web Hosting

### Basic Website (A + AAAA + www)
```
<domain>.           3600  IN  A      <ipv4-address>
<domain>.           3600  IN  AAAA   <ipv6-address>
www.<domain>.       3600  IN  CNAME  <domain>.
```

### Website Behind CDN (Cloudflare / CloudFront)
```
; Cloudflare (proxied) — use CNAME flattening at apex
<domain>.           300   IN  A      <cloudflare-ip>
www.<domain>.       300   IN  CNAME  <domain>.

; CloudFront — use Route 53 ALIAS or A record
<domain>.           300   IN  A      <cloudfront-ip>
; Or Route 53 ALIAS to d111111abcdef8.cloudfront.net
www.<domain>.       300   IN  CNAME  <distribution-id>.cloudfront.net.
```

### Static Site Hosting

```
; GitHub Pages
<domain>.           3600  IN  A      185.199.108.153
<domain>.           3600  IN  A      185.199.109.153
<domain>.           3600  IN  A      185.199.110.153
<domain>.           3600  IN  A      185.199.111.153
www.<domain>.       3600  IN  CNAME  <username>.github.io.

; Netlify
<domain>.           3600  IN  A      75.2.60.5
www.<domain>.       3600  IN  CNAME  <site-name>.netlify.app.

; Vercel
<domain>.           3600  IN  A      76.76.21.21
www.<domain>.       3600  IN  CNAME  cname.vercel-dns.com.

; AWS S3 Static Website
www.<domain>.       3600  IN  CNAME  <bucket>.s3-website-<region>.amazonaws.com.
```

---

## Email Providers

### Google Workspace
```
; MX
<domain>.  3600  IN  MX  1   ASPMX.L.GOOGLE.COM.
<domain>.  3600  IN  MX  5   ALT1.ASPMX.L.GOOGLE.COM.
<domain>.  3600  IN  MX  5   ALT2.ASPMX.L.GOOGLE.COM.
<domain>.  3600  IN  MX  10  ALT3.ASPMX.L.GOOGLE.COM.
<domain>.  3600  IN  MX  10  ALT4.ASPMX.L.GOOGLE.COM.

; SPF
<domain>.  3600  IN  TXT  "v=spf1 include:_spf.google.com -all"

; DKIM (get key from Google Admin Console)
google._domainkey.<domain>.  3600  IN  TXT  "v=DKIM1; k=rsa; p=<public-key>"

; DMARC
_dmarc.<domain>.  3600  IN  TXT  "v=DMARC1; p=reject; rua=mailto:dmarc@<domain>"
```

### Microsoft 365
```
; MX
<domain>.  3600  IN  MX  0  <domain-dashed>.mail.protection.outlook.com.

; SPF
<domain>.  3600  IN  TXT  "v=spf1 include:spf.protection.outlook.com -all"

; DKIM (CNAME records)
selector1._domainkey.<domain>.  CNAME  selector1-<domain-dashed>._domainkey.<tenant>.onmicrosoft.com.
selector2._domainkey.<domain>.  CNAME  selector2-<domain-dashed>._domainkey.<tenant>.onmicrosoft.com.

; DMARC
_dmarc.<domain>.  3600  IN  TXT  "v=DMARC1; p=reject; rua=mailto:dmarc@<domain>"

; Autodiscover
autodiscover.<domain>.  3600  IN  CNAME  autodiscover.outlook.com.
```

### AWS SES
```
; DKIM (3 CNAME records from SES console)
<token1>._domainkey.<domain>.  CNAME  <token1>.dkim.amazonses.com.
<token2>._domainkey.<domain>.  CNAME  <token2>.dkim.amazonses.com.
<token3>._domainkey.<domain>.  CNAME  <token3>.dkim.amazonses.com.

; SPF
<domain>.  3600  IN  TXT  "v=spf1 include:amazonses.com -all"

; Custom MAIL FROM
bounce.<domain>.  3600  IN  MX   10   feedback-smtp.<region>.amazonses.com.
bounce.<domain>.  3600  IN  TXT  "v=spf1 include:amazonses.com -all"

; DMARC
_dmarc.<domain>.  3600  IN  TXT  "v=DMARC1; p=reject; rua=mailto:dmarc@<domain>"
```

### Fastmail
```
; MX
<domain>.  3600  IN  MX  10  in1-smtp.messagingengine.com.
<domain>.  3600  IN  MX  20  in2-smtp.messagingengine.com.

; SPF
<domain>.  3600  IN  TXT  "v=spf1 include:spf.messagingengine.com -all"

; DKIM
fm1._domainkey.<domain>.  CNAME  fm1.<domain>.dkim.fmhosted.com.
fm2._domainkey.<domain>.  CNAME  fm2.<domain>.dkim.fmhosted.com.
fm3._domainkey.<domain>.  CNAME  fm3.<domain>.dkim.fmhosted.com.

; DMARC
_dmarc.<domain>.  3600  IN  TXT  "v=DMARC1; p=reject; rua=mailto:dmarc@<domain>"
```

---

## Domain Verification

```
; Google Search Console / Workspace
<domain>.  3600  IN  TXT  "google-site-verification=<code>"

; Microsoft 365
<domain>.  3600  IN  TXT  "MS=ms<code>"

; Apple Business / iCloud
<domain>.  3600  IN  TXT  "apple-domain-verification=<code>"

; Facebook Domain Verification
<domain>.  3600  IN  TXT  "facebook-domain-verification=<code>"

; Atlassian (Jira/Confluence Cloud)
<domain>.  3600  IN  TXT  "atlassian-domain-verification=<code>"

; Slack
<domain>.  3600  IN  TXT  "slack-domain-verification=<code>"

; Stripe
<domain>.  3600  IN  TXT  "stripe-verification=<code>"

; Let's Encrypt (DNS-01 challenge)
_acme-challenge.<domain>.  300  IN  TXT  "<challenge-token>"
```

---

## Security Records

### CAA (Certificate Authority Authorization)
```
; Allow only Let's Encrypt to issue certificates
<domain>.  3600  IN  CAA  0 issue "letsencrypt.org"
<domain>.  3600  IN  CAA  0 issuewild "letsencrypt.org"
<domain>.  3600  IN  CAA  0 iodef "mailto:security@<domain>"

; Allow multiple CAs
<domain>.  3600  IN  CAA  0 issue "letsencrypt.org"
<domain>.  3600  IN  CAA  0 issue "digicert.com"
<domain>.  3600  IN  CAA  0 issue "sectigo.com"

; Block all certificate issuance (paranoid mode)
<domain>.  3600  IN  CAA  0 issue ";"
<domain>.  3600  IN  CAA  0 issuewild ";"
```

### MTA-STS & TLS-RPT
```
; MTA-STS DNS record (change id on each policy update)
_mta-sts.<domain>.   3600  IN  TXT  "v=STSv1; id=<yyyymmddHHMMSS>"

; TLS-RPT (receive TLS failure reports)
_smtp._tls.<domain>. 3600  IN  TXT  "v=TLSRPTv1; rua=mailto:tls-reports@<domain>"
```

### BIMI (Brand Logo in Email)
```
; With VMC certificate (required for Gmail)
default._bimi.<domain>.  3600  IN  TXT  "v=BIMI1; l=https://<domain>/logo.svg; a=https://<domain>/vmc.pem;"

; Without VMC (works in Yahoo, Apple Mail)
default._bimi.<domain>.  3600  IN  TXT  "v=BIMI1; l=https://<domain>/logo.svg;"
```

---

## SaaS & Third-Party Services

### Load Balancers
```
; AWS ALB/ELB (use Route 53 ALIAS or CNAME for non-apex)
app.<domain>.  300  IN  CNAME  <lb-name>.<region>.elb.amazonaws.com.

; Google Cloud Load Balancer
app.<domain>.  300  IN  A  <static-ip>

; Azure Application Gateway
app.<domain>.  300  IN  CNAME  <gateway>.azurefd.net.
```

### Kubernetes Ingress
```
; Point to ingress controller external IP
app.<domain>.     300  IN  A      <ingress-ip>
*.app.<domain>.   300  IN  A      <ingress-ip>

; Or CNAME to cloud LB
app.<domain>.     300  IN  CNAME  <ingress-lb>.elb.amazonaws.com.
```

### SaaS Platforms
```
; Shopify
<domain>.           3600  IN  A      23.227.38.65
www.<domain>.       3600  IN  CNAME  shops.myshopify.com.

; Squarespace
<domain>.           3600  IN  A      198.185.159.144
<domain>.           3600  IN  A      198.185.159.145
<domain>.           3600  IN  A      198.49.23.144
<domain>.           3600  IN  A      198.49.23.145
www.<domain>.       3600  IN  CNAME  ext-cust.squarespace.com.

; Heroku
www.<domain>.       3600  IN  CNAME  <app-name>.herokuapp.com.
; Apex: use DNS provider's ALIAS/ANAME if available

; Render
<domain>.           3600  IN  A      <render-ip>
www.<domain>.       3600  IN  CNAME  <service>.onrender.com.
```

---

## Service Discovery

### SRV Records
```
; Format: _service._proto.name TTL IN SRV priority weight port target

; XMPP/Jabber
_xmpp-client._tcp.<domain>.  3600  IN  SRV  5 0 5222 xmpp.<domain>.
_xmpp-server._tcp.<domain>.  3600  IN  SRV  5 0 5269 xmpp.<domain>.

; SIP (Voice over IP)
_sip._tcp.<domain>.    3600  IN  SRV  10 60 5060 sip.<domain>.
_sip._udp.<domain>.    3600  IN  SRV  10 60 5060 sip.<domain>.
_sips._tcp.<domain>.   3600  IN  SRV  10 60 5061 sip.<domain>.

; Minecraft
_minecraft._tcp.<domain>.  3600  IN  SRV  0 5 25565 mc.<domain>.

; CalDAV / CardDAV (calendar & contacts)
_caldavs._tcp.<domain>.   3600  IN  SRV  0 0 443 caldav.<domain>.
_carddavs._tcp.<domain>.  3600  IN  SRV  0 0 443 carddav.<domain>.

; LDAP
_ldap._tcp.<domain>.  3600  IN  SRV  0 100 389 ldap.<domain>.
```

---

## DNS Failover & Load Balancing

### Round-Robin (Basic Load Balancing)
```
app.<domain>.  60  IN  A  10.0.1.1
app.<domain>.  60  IN  A  10.0.1.2
app.<domain>.  60  IN  A  10.0.1.3
```

### Weighted (Route 53 — via API/Console)
```json
{
  "Type": "A",
  "Name": "app.<domain>",
  "SetIdentifier": "primary",
  "Weight": 80,
  "TTL": 60,
  "ResourceRecords": [{"Value": "10.0.1.1"}]
}
```

### Geographic (Route 53)
```json
{
  "Type": "A",
  "Name": "app.<domain>",
  "SetIdentifier": "us",
  "GeoLocation": {"CountryCode": "US"},
  "TTL": 300,
  "ResourceRecords": [{"Value": "10.0.1.1"}]
}
```

---

## Wildcard Records

```
; Catch-all for undefined subdomains
*.<domain>.  300  IN  A  <ip-address>

; Wildcard SSL / web hosting
*.<domain>.  300  IN  CNAME  <hosting-provider>.

; Note: Explicit records always override wildcard
; www.<domain>. A 1.2.3.4  ← this takes precedence over *.example.com
```
