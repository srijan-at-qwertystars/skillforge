# Security Headers: Framework Configuration Reference

Copy-paste ready security header configurations for every major web framework, server, and deployment platform.

---

## Table of Contents

1. [Express.js / Helmet](#expressjs--helmet)
2. [Next.js](#nextjs)
3. [Nuxt.js](#nuxtjs)
4. [Django](#django)
5. [Spring Boot](#spring-boot)
6. [ASP.NET Core](#aspnet-core)
7. [Ruby on Rails](#ruby-on-rails)
8. [Nginx](#nginx)
9. [Apache](#apache)
10. [Caddy](#caddy)
11. [Cloudflare Workers](#cloudflare-workers)
12. [Vercel](#vercel)
13. [Netlify](#netlify)

---

## Express.js / Helmet

Install: `npm install helmet`

```javascript
const express = require('express');
const helmet = require('helmet');
const crypto = require('crypto');

const app = express();

// Generate nonce per request
app.use((req, res, next) => {
  res.locals.cspNonce = crypto.randomBytes(16).toString('base64');
  next();
});

app.use((req, res, next) => {
  const nonce = res.locals.cspNonce;
  helmet({
    // Content-Security-Policy
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'", `'nonce-${nonce}'`, "'strict-dynamic'", "https:", "'unsafe-inline'"],
        scriptSrcAttr: ["'none'"],
        styleSrc: ["'self'", `'nonce-${nonce}'`],
        imgSrc: ["'self'", "data:", "https:"],
        fontSrc: ["'self'", "https:"],
        connectSrc: ["'self'"],
        mediaSrc: ["'self'"],
        objectSrc: ["'none'"],
        frameSrc: ["'none'"],
        childSrc: ["'none'"],
        workerSrc: ["'self'"],
        frameAncestors: ["'none'"],
        formAction: ["'self'"],
        baseUri: ["'none'"],
        manifestSrc: ["'self'"],
        upgradeInsecureRequests: [],
      },
      reportOnly: false,
    },
    // Strict-Transport-Security
    strictTransportSecurity: {
      maxAge: 31536000,       // 1 year
      includeSubDomains: true,
      preload: true,
    },
    // X-Content-Type-Options: nosniff
    xContentTypeOptions: true,
    // X-Frame-Options: DENY (backup for frame-ancestors)
    xFrameOptions: { action: 'deny' },
    // Referrer-Policy
    referrerPolicy: { policy: 'strict-origin-when-cross-origin' },
    // X-DNS-Prefetch-Control
    xDnsPrefetchControl: { allow: false },
    // X-Download-Options (IE)
    xDownloadOptions: true,
    // X-Permitted-Cross-Domain-Policies
    xPermittedCrossDomainPolicies: { permittedPolicies: 'none' },
    // Cross-Origin-Embedder-Policy
    crossOriginEmbedderPolicy: { policy: 'require-corp' },
    // Cross-Origin-Opener-Policy
    crossOriginOpenerPolicy: { policy: 'same-origin' },
    // Cross-Origin-Resource-Policy
    crossOriginResourcePolicy: { policy: 'same-origin' },
  })(req, res, next);
});

// Permissions-Policy (Helmet doesn't set this — add manually)
app.use((req, res, next) => {
  res.setHeader('Permissions-Policy',
    'camera=(), microphone=(), geolocation=(), payment=(), usb=(), ' +
    'magnetometer=(), gyroscope=(), accelerometer=(), fullscreen=(self)');
  next();
});
```

**Without Helmet (manual headers):**

```javascript
app.use((req, res, next) => {
  const nonce = crypto.randomBytes(16).toString('base64');
  res.locals.cspNonce = nonce;

  res.setHeader('Content-Security-Policy',
    `default-src 'self'; script-src 'self' 'nonce-${nonce}' 'strict-dynamic'; ` +
    `style-src 'self' 'nonce-${nonce}'; img-src 'self' data:; ` +
    `object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`);
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
  next();
});
```

---

## Next.js

### next.config.js (static headers)

```javascript
// next.config.js
/** @type {import('next').NextConfig} */
const nextConfig = {
  async headers() {
    return [
      {
        source: '/(.*)',
        headers: [
          {
            key: 'Strict-Transport-Security',
            value: 'max-age=31536000; includeSubDomains; preload',
          },
          {
            key: 'X-Content-Type-Options',
            value: 'nosniff',
          },
          {
            key: 'X-Frame-Options',
            value: 'DENY',
          },
          {
            key: 'Referrer-Policy',
            value: 'strict-origin-when-cross-origin',
          },
          {
            key: 'Permissions-Policy',
            value: 'camera=(), microphone=(), geolocation=(), payment=()',
          },
          {
            key: 'X-DNS-Prefetch-Control',
            value: 'on',
          },
          {
            key: 'Cross-Origin-Opener-Policy',
            value: 'same-origin',
          },
          {
            key: 'Cross-Origin-Resource-Policy',
            value: 'same-origin',
          },
        ],
      },
    ];
  },
};

module.exports = nextConfig;
```

### Nonce-Based CSP with Middleware

```typescript
// middleware.ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

export function middleware(request: NextRequest) {
  const nonce = Buffer.from(crypto.randomUUID()).toString('base64');

  const csp = [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic' https: 'unsafe-inline'`,
    `style-src 'self' 'nonce-${nonce}'`,
    "img-src 'self' data: blob: https:",
    "font-src 'self' https:",
    "connect-src 'self'",
    "object-src 'none'",
    "base-uri 'none'",
    "frame-ancestors 'none'",
    "form-action 'self'",
    "upgrade-insecure-requests",
  ].join('; ');

  const response = NextResponse.next();
  response.headers.set('Content-Security-Policy', csp);
  response.headers.set('x-nonce', nonce);
  return response;
}

export const config = {
  matcher: [
    { source: '/((?!api|_next/static|_next/image|favicon.ico).*)' },
  ],
};
```

```tsx
// app/layout.tsx — access nonce in Server Components
import { headers } from 'next/headers';
import Script from 'next/script';

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const headersList = await headers();
  const nonce = headersList.get('x-nonce') ?? '';

  return (
    <html lang="en">
      <body>
        {children}
        <Script nonce={nonce} strategy="afterInteractive" src="/analytics.js" />
      </body>
    </html>
  );
}
```

---

## Nuxt.js

### Nuxt 3

```typescript
// nuxt.config.ts
export default defineNuxtConfig({
  routeRules: {
    '/**': {
      headers: {
        'Strict-Transport-Security': 'max-age=31536000; includeSubDomains; preload',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'Referrer-Policy': 'strict-origin-when-cross-origin',
        'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
        'Cross-Origin-Opener-Policy': 'same-origin',
        'Cross-Origin-Resource-Policy': 'same-origin',
      },
    },
  },
});
```

### Nonce-based CSP with Server Middleware

```typescript
// server/middleware/csp.ts
import { randomBytes } from 'node:crypto';

export default defineEventHandler((event) => {
  const nonce = randomBytes(16).toString('base64');
  event.context.cspNonce = nonce;

  setResponseHeader(event, 'Content-Security-Policy', [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`,
    `style-src 'self' 'nonce-${nonce}'`,
    "img-src 'self' data:",
    "object-src 'none'",
    "base-uri 'none'",
    "frame-ancestors 'none'",
  ].join('; '));
});
```

```vue
<!-- Access nonce in components -->
<script setup>
const nonce = useRequestEvent()?.context.cspNonce;
</script>

<template>
  <Head>
    <Script :nonce="nonce" src="/analytics.js" />
  </Head>
</template>
```

---

## Django

### settings.py (SecurityMiddleware)

```python
# settings.py

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    # ... other middleware
]

# HSTS
SECURE_HSTS_SECONDS = 31536000       # 1 year
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = True

# HTTPS redirect
SECURE_SSL_REDIRECT = True

# X-Content-Type-Options
SECURE_CONTENT_TYPE_NOSNIFF = True

# Referrer-Policy
SECURE_REFERRER_POLICY = 'strict-origin-when-cross-origin'

# Cross-Origin-Opener-Policy
SECURE_CROSS_ORIGIN_OPENER_POLICY = 'same-origin'

# X-Frame-Options (fallback for frame-ancestors)
X_FRAME_OPTIONS = 'DENY'

# Session cookie security
SESSION_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = 'Strict'
CSRF_COOKIE_SECURE = True
CSRF_COOKIE_HTTPONLY = True
CSRF_COOKIE_SAMESITE = 'Strict'
```

### CSP with django-csp

Install: `pip install django-csp`

```python
# settings.py
MIDDLEWARE = [
    'csp.middleware.CSPMiddleware',
    'django.middleware.security.SecurityMiddleware',
    # ...
]

# CSP configuration
CSP_DEFAULT_SRC = ("'self'",)
CSP_SCRIPT_SRC = ("'self'",)
CSP_STYLE_SRC = ("'self'",)
CSP_IMG_SRC = ("'self'", "data:")
CSP_FONT_SRC = ("'self'",)
CSP_CONNECT_SRC = ("'self'",)
CSP_OBJECT_SRC = ("'none'",)
CSP_BASE_URI = ("'none'",)
CSP_FRAME_ANCESTORS = ("'none'",)
CSP_FORM_ACTION = ("'self'",)
CSP_INCLUDE_NONCE_IN = ['script-src', 'style-src']
CSP_UPGRADE_INSECURE_REQUESTS = True

# Report violations
# CSP_REPORT_URI = '/csp-report/'
# Or use report-only mode for testing:
# CSP_REPORT_ONLY = True
```

```html
<!-- Django template — use the nonce -->
{% load csp %}
<script nonce="{% csp_nonce %}">
  initApp();
</script>
```

---

## Spring Boot

### WebSecurityConfig.java

```java
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.header.writers.*;

@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http.headers(headers -> headers
            // Content-Security-Policy
            .contentSecurityPolicy(csp -> csp
                .policyDirectives(
                    "default-src 'self'; " +
                    "script-src 'self'; " +
                    "style-src 'self'; " +
                    "img-src 'self' data:; " +
                    "object-src 'none'; " +
                    "base-uri 'none'; " +
                    "frame-ancestors 'none'; " +
                    "form-action 'self'"
                )
            )
            // Strict-Transport-Security
            .httpStrictTransportSecurity(hsts -> hsts
                .includeSubDomains(true)
                .maxAgeInSeconds(31536000)
                .preload(true)
            )
            // X-Content-Type-Options: nosniff (enabled by default)
            .contentTypeOptions(contentType -> {})
            // X-Frame-Options: DENY
            .frameOptions(frame -> frame.deny())
            // Referrer-Policy
            .referrerPolicy(referrer -> referrer
                .policy(ReferrerPolicyHeaderWriter.ReferrerPolicy.STRICT_ORIGIN_WHEN_CROSS_ORIGIN)
            )
            // Permissions-Policy
            .permissionsPolicy(permissions -> permissions
                .policy("camera=(), microphone=(), geolocation=(), payment=()")
            )
            // Cross-Origin policies
            .crossOriginOpenerPolicy(coop -> coop
                .policy(CrossOriginOpenerPolicyHeaderWriter.CrossOriginOpenerPolicy.SAME_ORIGIN)
            )
            .crossOriginResourcePolicy(corp -> corp
                .policy(CrossOriginResourcePolicyHeaderWriter.CrossOriginResourcePolicy.SAME_ORIGIN)
            )
        );

        return http.build();
    }
}
```

### application.properties (basic headers)

```properties
# HSTS (requires HTTPS)
server.servlet.session.cookie.secure=true
server.servlet.session.cookie.http-only=true
server.servlet.session.cookie.same-site=strict
```

---

## ASP.NET Core

### Middleware Approach

```csharp
// Program.cs or Startup.cs
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

// Security headers middleware
app.Use(async (context, next) =>
{
    var headers = context.Response.Headers;

    // Content-Security-Policy
    headers.Append("Content-Security-Policy",
        "default-src 'self'; " +
        "script-src 'self'; " +
        "style-src 'self'; " +
        "img-src 'self' data:; " +
        "object-src 'none'; " +
        "base-uri 'none'; " +
        "frame-ancestors 'none'; " +
        "form-action 'self'; " +
        "upgrade-insecure-requests");

    // Strict-Transport-Security
    headers.Append("Strict-Transport-Security",
        "max-age=31536000; includeSubDomains; preload");

    // X-Content-Type-Options
    headers.Append("X-Content-Type-Options", "nosniff");

    // X-Frame-Options
    headers.Append("X-Frame-Options", "DENY");

    // Referrer-Policy
    headers.Append("Referrer-Policy", "strict-origin-when-cross-origin");

    // Permissions-Policy
    headers.Append("Permissions-Policy",
        "camera=(), microphone=(), geolocation=(), payment=()");

    // Cross-Origin headers
    headers.Append("Cross-Origin-Opener-Policy", "same-origin");
    headers.Append("Cross-Origin-Resource-Policy", "same-origin");

    // Remove server identification
    headers.Remove("Server");
    headers.Remove("X-Powered-By");

    await next();
});

// HSTS built-in (production only)
if (!app.Environment.IsDevelopment())
{
    app.UseHsts();
}
app.UseHttpsRedirection();
```

### With NWebsec Package

Install: `dotnet add package NWebsec.AspNetCore.Middleware`

```csharp
app.UseCsp(options => options
    .DefaultSources(s => s.Self())
    .ScriptSources(s => s.Self())
    .StyleSources(s => s.Self())
    .ImageSources(s => s.Self().CustomSources("data:"))
    .ObjectSources(s => s.None())
    .BaseUris(s => s.None())
    .FrameAncestors(s => s.None())
    .FormActions(s => s.Self())
);

app.UseXContentTypeOptions();
app.UseXfo(options => options.Deny());
app.UseReferrerPolicy(options => options.StrictOriginWhenCrossOrigin());
```

---

## Ruby on Rails

### config/application.rb

```ruby
# config/application.rb or config/environments/production.rb
module MyApp
  class Application < Rails::Application
    # Force HTTPS
    config.force_ssl = true

    # HSTS
    config.ssl_options = {
      hsts: { subdomains: true, preload: true, expires: 1.year }
    }

    # X-Frame-Options
    config.action_dispatch.default_headers['X-Frame-Options'] = 'DENY'

    # X-Content-Type-Options
    config.action_dispatch.default_headers['X-Content-Type-Options'] = 'nosniff'

    # Referrer-Policy
    config.action_dispatch.default_headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'

    # Permissions-Policy
    config.action_dispatch.default_headers['Permissions-Policy'] = 'camera=(), microphone=(), geolocation=()'

    # Cross-Origin headers
    config.action_dispatch.default_headers['Cross-Origin-Opener-Policy'] = 'same-origin'
    config.action_dispatch.default_headers['Cross-Origin-Resource-Policy'] = 'same-origin'

    # Content-Security-Policy
    config.content_security_policy do |policy|
      policy.default_src :self
      policy.script_src  :self
      policy.style_src   :self
      policy.img_src     :self, :data
      policy.font_src    :self
      policy.connect_src :self
      policy.object_src  :none
      policy.base_uri    :none
      policy.frame_ancestors :none
      policy.form_action :self
    end

    # Generate nonces for scripts and styles
    config.content_security_policy_nonce_generator = ->(request) {
      SecureRandom.base64(16)
    }
    config.content_security_policy_nonce_directives = %w[script-src style-src]

    # Report-only mode for testing
    # config.content_security_policy_report_only = true
  end
end
```

```erb
<!-- In views, use the nonce helper -->
<%= javascript_tag nonce: true do %>
  initApp();
<% end %>

<%= stylesheet_link_tag 'application', nonce: true %>
```

---

## Nginx

```nginx
# /etc/nginx/snippets/security-headers.conf
# Include this in your server blocks: include snippets/security-headers.conf;

# Content-Security-Policy
# Customize directives for your application
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; upgrade-insecure-requests" always;

# Strict-Transport-Security (only on HTTPS server blocks)
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

# X-Content-Type-Options
add_header X-Content-Type-Options "nosniff" always;

# X-Frame-Options (backup for frame-ancestors)
add_header X-Frame-Options "DENY" always;

# Referrer-Policy
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# Permissions-Policy
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=()" always;

# Cross-Origin-Opener-Policy
add_header Cross-Origin-Opener-Policy "same-origin" always;

# Cross-Origin-Resource-Policy
add_header Cross-Origin-Resource-Policy "same-origin" always;

# Remove server version
server_tokens off;
```

```nginx
# Full server block example
server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate /etc/ssl/certs/example.com.pem;
    ssl_certificate_key /etc/ssl/private/example.com.key;

    include snippets/security-headers.conf;

    # IMPORTANT: headers in nested location blocks override parent.
    # Repeat headers in each location block or use map variables.
    location / {
        proxy_pass http://app:3000;
        include snippets/security-headers.conf;
    }

    location /api/ {
        proxy_pass http://api:8080;
        include snippets/security-headers.conf;
        # Override CSP for API routes if needed
        add_header Content-Security-Policy "default-src 'none'; frame-ancestors 'none'" always;
    }
}

# HTTP to HTTPS redirect
server {
    listen 80;
    server_name example.com;
    return 301 https://$server_name$request_uri;
}
```

---

## Apache

```apache
# /etc/apache2/conf-available/security-headers.conf
# Enable: a2enconf security-headers && systemctl reload apache2
# Requires: a2enmod headers

# Content-Security-Policy
Header always set Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; upgrade-insecure-requests"

# Strict-Transport-Security
Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"

# X-Content-Type-Options
Header always set X-Content-Type-Options "nosniff"

# X-Frame-Options
Header always set X-Frame-Options "DENY"

# Referrer-Policy
Header always set Referrer-Policy "strict-origin-when-cross-origin"

# Permissions-Policy
Header always set Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()"

# Cross-Origin-Opener-Policy
Header always set Cross-Origin-Opener-Policy "same-origin"

# Cross-Origin-Resource-Policy
Header always set Cross-Origin-Resource-Policy "same-origin"

# Remove server version info
ServerTokens Prod
ServerSignature Off
Header always unset X-Powered-By
```

```apache
# .htaccess version (if mod_headers is loaded)
<IfModule mod_headers.c>
    Header always set Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "DENY"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "camera=(), microphone=(), geolocation=()"
</IfModule>
```

---

## Caddy

```
# Caddyfile
example.com {
    # Caddy enables HTTPS and HSTS automatically

    header {
        # Content-Security-Policy
        Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; upgrade-insecure-requests"

        # X-Content-Type-Options
        X-Content-Type-Options "nosniff"

        # X-Frame-Options
        X-Frame-Options "DENY"

        # Referrer-Policy
        Referrer-Policy "strict-origin-when-cross-origin"

        # Permissions-Policy
        Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()"

        # Cross-Origin headers
        Cross-Origin-Opener-Policy "same-origin"
        Cross-Origin-Resource-Policy "same-origin"

        # Remove server header
        -Server
    }

    reverse_proxy localhost:3000
}
```

Caddy automatically provisions TLS certificates and sets HSTS. Override HSTS if needed:

```
example.com {
    header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    # ...
}
```

---

## Cloudflare Workers

```javascript
// worker.js
export default {
  async fetch(request, env) {
    const response = await fetch(request);

    // Clone response to modify headers
    const newResponse = new Response(response.body, response);

    // Content-Security-Policy
    newResponse.headers.set('Content-Security-Policy',
      "default-src 'self'; " +
      "script-src 'self'; " +
      "style-src 'self'; " +
      "img-src 'self' data:; " +
      "object-src 'none'; " +
      "base-uri 'none'; " +
      "frame-ancestors 'none'; " +
      "form-action 'self'; " +
      "upgrade-insecure-requests");

    // Strict-Transport-Security
    newResponse.headers.set('Strict-Transport-Security',
      'max-age=31536000; includeSubDomains; preload');

    // X-Content-Type-Options
    newResponse.headers.set('X-Content-Type-Options', 'nosniff');

    // X-Frame-Options
    newResponse.headers.set('X-Frame-Options', 'DENY');

    // Referrer-Policy
    newResponse.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');

    // Permissions-Policy
    newResponse.headers.set('Permissions-Policy',
      'camera=(), microphone=(), geolocation=(), payment=()');

    // Cross-Origin headers
    newResponse.headers.set('Cross-Origin-Opener-Policy', 'same-origin');
    newResponse.headers.set('Cross-Origin-Resource-Policy', 'same-origin');

    // Remove server identification
    newResponse.headers.delete('Server');
    newResponse.headers.delete('X-Powered-By');

    return newResponse;
  },
};
```

### With nonce generation

```javascript
export default {
  async fetch(request, env) {
    const response = await fetch(request);
    const nonce = btoa(crypto.getRandomValues(new Uint8Array(16)).join(''));

    const newResponse = new Response(response.body, response);
    newResponse.headers.set('Content-Security-Policy',
      `default-src 'self'; ` +
      `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'; ` +
      `style-src 'self' 'nonce-${nonce}'; ` +
      `object-src 'none'; base-uri 'none'; frame-ancestors 'none'`);

    return newResponse;
  },
};
```

---

## Vercel

### vercel.json

```json
{
  "headers": [
    {
      "source": "/(.*)",
      "headers": [
        {
          "key": "Content-Security-Policy",
          "value": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; upgrade-insecure-requests"
        },
        {
          "key": "Strict-Transport-Security",
          "value": "max-age=31536000; includeSubDomains; preload"
        },
        {
          "key": "X-Content-Type-Options",
          "value": "nosniff"
        },
        {
          "key": "X-Frame-Options",
          "value": "DENY"
        },
        {
          "key": "Referrer-Policy",
          "value": "strict-origin-when-cross-origin"
        },
        {
          "key": "Permissions-Policy",
          "value": "camera=(), microphone=(), geolocation=(), payment=()"
        },
        {
          "key": "Cross-Origin-Opener-Policy",
          "value": "same-origin"
        },
        {
          "key": "Cross-Origin-Resource-Policy",
          "value": "same-origin"
        }
      ]
    }
  ]
}
```

**Note:** Vercel sets HSTS automatically on `*.vercel.app` domains. For custom domains, set it explicitly. For nonce-based CSP on Vercel, use Next.js middleware (see Next.js section) or Vercel Edge Middleware.

---

## Netlify

### netlify.toml

```toml
[[headers]]
  for = "/*"
  [headers.values]
    Content-Security-Policy = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; upgrade-insecure-requests"
    Strict-Transport-Security = "max-age=31536000; includeSubDomains; preload"
    X-Content-Type-Options = "nosniff"
    X-Frame-Options = "DENY"
    Referrer-Policy = "strict-origin-when-cross-origin"
    Permissions-Policy = "camera=(), microphone=(), geolocation=(), payment=()"
    Cross-Origin-Opener-Policy = "same-origin"
    Cross-Origin-Resource-Policy = "same-origin"
```

### _headers file (alternative)

```
/*
  Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; upgrade-insecure-requests
  Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Resource-Policy: same-origin
```

**Note:** Netlify automatically enables HTTPS and sets basic HSTS. The `_headers` file goes in your publish directory. For nonce-based CSP, use Netlify Edge Functions.

### Netlify Edge Function (for nonces)

```typescript
// netlify/edge-functions/csp-nonce.ts
import type { Context } from "https://edge.netlify.com";

export default async (request: Request, context: Context) => {
  const response = await context.next();
  const nonce = btoa(crypto.getRandomValues(new Uint8Array(16)).toString());

  response.headers.set('Content-Security-Policy',
    `default-src 'self'; script-src 'self' 'nonce-${nonce}' 'strict-dynamic'; ` +
    `style-src 'self' 'nonce-${nonce}'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'`);

  return response;
};
```
