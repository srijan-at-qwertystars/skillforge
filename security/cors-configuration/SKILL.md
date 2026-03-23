---
name: cors-configuration
description:
  positive: "Use when user configures CORS headers, debugs CORS errors ('has been blocked by CORS policy'), asks about preflight requests, Access-Control-Allow-Origin, credentials with CORS, or CORS in Express/Django/Spring/Nginx/API Gateway."
  negative: "Do NOT use for general HTTP headers, CSP (Content-Security-Policy), or same-origin page security unrelated to cross-origin requests."
---

# CORS Configuration

## How CORS Works

The **same-origin policy** blocks web pages from making requests to a different origin (scheme + host + port). CORS relaxes this by letting servers declare which origins may access their resources via HTTP response headers.

### Simple Requests

A request is "simple" (no preflight) when ALL of these hold:
- Method is `GET`, `HEAD`, or `POST`.
- Only CORS-safelisted headers are used (`Accept`, `Accept-Language`, `Content-Language`, `Content-Type`).
- `Content-Type` is `application/x-www-form-urlencoded`, `multipart/form-data`, or `text/plain`.
- No `ReadableStream` body.
- No event listeners on `XMLHttpRequest.upload`.

### Preflighted Requests

Any request not meeting simple criteria triggers a **preflight**: the browser sends an `OPTIONS` request first with:
- `Origin`
- `Access-Control-Request-Method`
- `Access-Control-Request-Headers`

The server must respond with matching `Access-Control-Allow-*` headers and a `2xx` status. Only then does the browser send the actual request.

---

## CORS Headers Reference

| Header | Direction | Purpose |
|---|---|---|
| `Access-Control-Allow-Origin` | Response | Origin allowed to read the response. Use exact origin or `*`. |
| `Access-Control-Allow-Methods` | Response (preflight) | HTTP methods the server permits. |
| `Access-Control-Allow-Headers` | Response (preflight) | Request headers the server permits. |
| `Access-Control-Allow-Credentials` | Response | Set `true` to allow cookies/auth headers. Prohibits `*` origin. |
| `Access-Control-Max-Age` | Response (preflight) | Seconds the browser may cache the preflight result. |
| `Access-Control-Expose-Headers` | Response | Headers the client JS can read beyond the CORS-safelisted set. |
| `Access-Control-Request-Method` | Request (preflight) | Method the actual request will use. |
| `Access-Control-Request-Headers` | Request (preflight) | Custom headers the actual request will send. |

---

## Preflight Mechanics

### When a Preflight Fires

- `PUT`, `DELETE`, `PATCH`, or any non-simple method.
- Custom headers (e.g., `Authorization`, `X-Request-ID`).
- `Content-Type` other than the three safelisted values.
- Request uses `ReadableStream`.

### Caching Preflights

Set `Access-Control-Max-Age` to reduce OPTIONS traffic:
- `600` (10 min) is a safe default.
- `86400` (24 h) is the max most browsers honor.
- Chrome caps at 7200 s; Firefox at 86400 s.

Always include `Vary: Origin` when the `Access-Control-Allow-Origin` value changes per request.

---

## Credentials and Cookies

To send cookies or `Authorization` headers cross-origin:

1. **Client** — set `credentials: 'include'` (fetch) or `withCredentials = true` (XHR).
2. **Server** — respond with:
   - `Access-Control-Allow-Credentials: true`
   - An explicit origin in `Access-Control-Allow-Origin` (not `*`).
   - `Access-Control-Allow-Headers` must not be `*`.
   - `Access-Control-Allow-Methods` must not be `*`.
   - `Access-Control-Expose-Headers` must not be `*`.

### SameSite Cookie Interaction

- `SameSite=None; Secure` is required for cross-origin cookie sending.
- `SameSite=Lax` or `Strict` blocks the cookie regardless of CORS headers.

---

## Framework Configuration

### Express.js (cors middleware)

```js
const cors = require('cors');

const corsOptions = {
  origin: ['https://app.example.com', 'https://admin.example.com'],
  methods: ['GET', 'POST', 'PUT', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  credentials: true,
  maxAge: 600,
};

app.use(cors(corsOptions));
```

Dynamic origin validation:

```js
const allowedOrigins = new Set([
  'https://app.example.com',
  'https://admin.example.com',
]);

app.use(cors({
  origin(origin, callback) {
    if (!origin || allowedOrigins.has(origin)) {
      callback(null, true);
    } else {
      callback(new Error('CORS not allowed'));
    }
  },
  credentials: true,
}));
```

### Django (django-cors-headers)

```
pip install django-cors-headers
```

`settings.py`:

```python
INSTALLED_APPS = [
    # ...
    'corsheaders',
]

MIDDLEWARE = [
    'corsheaders.middleware.CorsMiddleware',  # before CommonMiddleware
    'django.middleware.common.CommonMiddleware',
    # ...
]

CORS_ALLOWED_ORIGINS = [
    'https://app.example.com',
]
CORS_ALLOW_CREDENTIALS = True
CORS_ALLOW_HEADERS = ['content-type', 'authorization']
CORS_PREFLIGHT_MAX_AGE = 600
```

### Flask (flask-cors)

```python
from flask import Flask
from flask_cors import CORS

app = Flask(__name__)
CORS(app, resources={r"/api/*": {
    "origins": ["https://app.example.com"],
    "methods": ["GET", "POST", "PUT", "DELETE"],
    "allow_headers": ["Content-Type", "Authorization"],
    "supports_credentials": True,
    "max_age": 600,
}})
```

### Spring Boot

```java
@Configuration
public class CorsConfig implements WebMvcConfigurer {
    @Override
    public void addCorsMappings(CorsRegistry registry) {
        registry.addMapping("/api/**")
            .allowedOrigins("https://app.example.com")
            .allowedMethods("GET", "POST", "PUT", "DELETE")
            .allowedHeaders("Content-Type", "Authorization")
            .allowCredentials(true)
            .maxAge(600);
    }
}
```

With Spring Security, also enable CORS in the security filter chain:

```java
@Bean
SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http.cors(c -> c.configurationSource(request -> {
        var config = new CorsConfiguration();
        config.setAllowedOrigins(List.of("https://app.example.com"));
        config.setAllowedMethods(List.of("GET", "POST", "PUT", "DELETE"));
        config.setAllowCredentials(true);
        config.setMaxAge(600L);
        return config;
    }));
    return http.build();
}
```

### ASP.NET Core

`Program.cs`:

```csharp
builder.Services.AddCors(options => {
    options.AddPolicy("Production", policy => {
        policy.WithOrigins("https://app.example.com")
              .WithMethods("GET", "POST", "PUT", "DELETE")
              .WithHeaders("Content-Type", "Authorization")
              .AllowCredentials()
              .SetPreflightMaxAge(TimeSpan.FromSeconds(600));
    });
});

// After Build()
app.UseCors("Production");
```

### Go (net/http)

```go
func corsMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        origin := r.Header.Get("Origin")
        if isAllowedOrigin(origin) {
            w.Header().Set("Access-Control-Allow-Origin", origin)
            w.Header().Set("Access-Control-Allow-Credentials", "true")
            w.Header().Set("Vary", "Origin")
        }
        if r.Method == http.MethodOptions {
            w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE")
            w.Header().Set("Access-Control-Allow-Headers", "Content-Type,Authorization")
            w.Header().Set("Access-Control-Max-Age", "600")
            w.WriteHeader(http.StatusNoContent)
            return
        }
        next.ServeHTTP(w, r)
    })
}
```

### Nginx

```nginx
map $http_origin $cors_origin {
    default "";
    "https://app.example.com" $http_origin;
    "https://admin.example.com" $http_origin;
}

server {
    location /api/ {
        if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' $cors_origin always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE' always;
            add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization' always;
            add_header 'Access-Control-Allow-Credentials' 'true' always;
            add_header 'Access-Control-Max-Age' '600' always;
            add_header 'Vary' 'Origin' always;
            return 204;
        }
        add_header 'Access-Control-Allow-Origin' $cors_origin always;
        add_header 'Access-Control-Allow-Credentials' 'true' always;
        add_header 'Vary' 'Origin' always;
        proxy_pass http://backend;
    }
}
```

Use `always` so headers appear on error responses too.

### AWS API Gateway (REST API)

Enable CORS in the console or via SAM/CloudFormation:

```yaml
# SAM template
MyApi:
  Type: AWS::Serverless::Api
  Properties:
    Cors:
      AllowMethods: "'GET,POST,PUT,DELETE'"
      AllowHeaders: "'Content-Type,Authorization'"
      AllowOrigin: "'https://app.example.com'"
      AllowCredentials: true
      MaxAge: "'600'"
```

For HTTP APIs, configure via `CorsConfiguration`:

```yaml
MyHttpApi:
  Type: AWS::Serverless::HttpApi
  Properties:
    CorsConfiguration:
      AllowOrigins:
        - https://app.example.com
      AllowMethods:
        - GET
        - POST
        - PUT
        - DELETE
      AllowHeaders:
        - Content-Type
        - Authorization
      AllowCredentials: true
      MaxAge: 600
```

---

## Common CORS Errors and Solutions

### "blocked by CORS policy: No 'Access-Control-Allow-Origin' header"

Server is not returning the header. Add CORS middleware/config. Verify the header appears on **error** responses too (Nginx `always`, Express error handler).

### "The value of 'Access-Control-Allow-Origin' must not be wildcard '*' when credentials mode is 'include'"

Replace `*` with the requesting origin. Validate against an allowlist. Set `Vary: Origin`.

### "Method PUT is not allowed by Access-Control-Allow-Methods"

Add the method to `Access-Control-Allow-Methods` in the preflight response.

### "Request header field authorization is not allowed by Access-Control-Allow-Headers"

Add `Authorization` (or the missing header) to `Access-Control-Allow-Headers`.

### Preflight returns non-2xx status

Ensure the server handles `OPTIONS` requests at the target path and returns `200` or `204`.

### "Response to preflight request doesn't pass access control check: redirect is not allowed"

The OPTIONS request is being redirected (e.g., HTTP→HTTPS or trailing slash). Fix the URL or routing so OPTIONS reaches the handler without redirects.

---

## Security Considerations

- **Never use `Access-Control-Allow-Origin: *` in production** for authenticated APIs. Attackers can read responses from any origin.
- **Validate origins against an allowlist.** Do not blindly reflect the `Origin` header—this is equivalent to `*` and defeats CORS protection.
- **Restrict methods and headers** to what the API actually uses. Do not allow `*`.
- **Set `Vary: Origin`** when the response changes based on the request origin, so caches and CDNs store separate copies.
- **Audit CORS config regularly.** Overly permissive CORS is an OWASP misconfiguration finding.
- **Do not rely on CORS alone for security.** Always validate authentication and authorization server-side.

---

## CORS with Authentication

### Bearer Tokens

Bearer tokens in the `Authorization` header trigger a preflight. Ensure `Access-Control-Allow-Headers` includes `Authorization`. No need for `credentials: true` unless also sending cookies.

### Cookies / Session Auth

Requires `credentials: 'include'` on the client and `Access-Control-Allow-Credentials: true` on the server. Set cookies with `SameSite=None; Secure; HttpOnly`. The origin must be explicit (not `*`).

### OAuth Redirect Flows

CORS does not apply to full-page navigations. OAuth redirects work without CORS. Token exchange endpoints (API calls) still need CORS if called from JS.

---

## CORS Proxy Patterns (Development Only)

### Webpack Dev Server

```js
// webpack.config.js
devServer: {
  proxy: {
    '/api': {
      target: 'http://localhost:8080',
      changeOrigin: true,
    },
  },
}
```

### Vite

```js
// vite.config.js
export default {
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
    },
  },
};
```

### create-react-app

Add to `package.json`:

```json
{
  "proxy": "http://localhost:8080"
}
```

Never deploy a CORS proxy to production. Fix server-side CORS instead.

---

## Testing and Debugging CORS

### curl

Simulate a preflight:

```bash
curl -i -X OPTIONS https://api.example.com/data \
  -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: PUT" \
  -H "Access-Control-Request-Headers: Authorization"
```

Check the response for `Access-Control-Allow-Origin`, `Access-Control-Allow-Methods`, and `Access-Control-Allow-Headers`.

Simulate a simple request:

```bash
curl -i https://api.example.com/data \
  -H "Origin: https://app.example.com"
```

### Browser DevTools

1. Open Network tab → filter by the failed request.
2. Look for the OPTIONS preflight preceding the actual request.
3. Inspect response headers on the preflight—missing headers indicate server misconfiguration.
4. Console shows the specific CORS violation message.

### Postman

Postman does not enforce CORS (no browser involved). Use it to verify API responses include correct headers, but always confirm in a real browser.

---

## Anti-Patterns

| Anti-Pattern | Why It's Dangerous | Fix |
|---|---|---|
| `Access-Control-Allow-Origin: *` on authenticated APIs | Any site can read user data | Use an explicit allowlist |
| Reflecting `Origin` header without validation | Equivalent to `*`; any origin is accepted | Check against an allowlist before reflecting |
| `Access-Control-Allow-Methods: *` | Permits arbitrary methods including `DELETE` | List only required methods |
| `Access-Control-Allow-Headers: *` | Permits arbitrary headers; breaks with credentials | List only required headers |
| Disabling CORS via browser extension in dev | Masks real bugs that hit production | Use a dev proxy instead |
| CORS proxy in production | Bypasses origin checks; adds latency and a trust boundary | Configure server CORS properly |
| Missing `Vary: Origin` with dynamic origins | Caches serve wrong origin's response to other origins | Always set `Vary: Origin` |

<!-- tested: pass -->
