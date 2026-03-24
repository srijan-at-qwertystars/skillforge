// njs Authentication Examples
// Demonstrates JWT validation, API key auth, and basic auth with njs
// Usage: js_import auth from auth.js; in nginx.conf
// Requires: load_module modules/ngx_http_js_module.so;

/**
 * Validate JWT tokens without an external auth service.
 * Use as: auth_request with js_content, or js_set for variable extraction.
 *
 * nginx.conf:
 *   location /api/ {
 *       auth_request /jwt_validate;
 *       auth_request_set $jwt_sub $upstream_http_x_jwt_sub;
 *       proxy_set_header X-User $jwt_sub;
 *       proxy_pass http://backend;
 *   }
 *   location = /jwt_validate {
 *       internal;
 *       js_content auth.validateJWT;
 *   }
 */
function validateJWT(r) {
    let auth = r.headersIn['Authorization'];

    if (!auth || !auth.startsWith('Bearer ')) {
        r.return(401, JSON.stringify({ error: 'Missing or invalid Authorization header' }));
        return;
    }

    let token = auth.slice(7);
    let parts = token.split('.');

    if (parts.length !== 3) {
        r.return(401, JSON.stringify({ error: 'Malformed JWT' }));
        return;
    }

    try {
        // Decode payload (signature verification requires crypto module in njs 0.7+)
        let payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString());

        // Check expiration
        let now = Math.floor(Date.now() / 1000);
        if (payload.exp && payload.exp < now) {
            r.return(401, JSON.stringify({ error: 'Token expired' }));
            return;
        }

        // Check not-before
        if (payload.nbf && payload.nbf > now) {
            r.return(401, JSON.stringify({ error: 'Token not yet valid' }));
            return;
        }

        // Check issuer if required
        let expectedIssuer = process.env.JWT_ISSUER || '';
        if (expectedIssuer && payload.iss !== expectedIssuer) {
            r.return(403, JSON.stringify({ error: 'Invalid issuer' }));
            return;
        }

        // Set response headers for auth_request_set to capture
        r.headersOut['X-JWT-Sub'] = payload.sub || '';
        r.headersOut['X-JWT-Roles'] = (payload.roles || []).join(',');
        r.headersOut['X-JWT-Email'] = payload.email || '';
        r.headersOut['X-JWT-Tenant'] = payload.tenant_id || '';

        r.return(200);
    } catch (e) {
        r.return(401, JSON.stringify({ error: 'Invalid JWT payload' }));
    }
}

/**
 * Extract JWT subject as an nginx variable.
 *
 * nginx.conf:
 *   js_set $jwt_subject auth.jwtSubject;
 *   proxy_set_header X-User $jwt_subject;
 */
function jwtSubject(r) {
    let auth = r.headersIn['Authorization'] || '';
    if (!auth.startsWith('Bearer ')) return '';

    try {
        let parts = auth.slice(7).split('.');
        let payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
        return payload.sub || '';
    } catch (e) {
        return '';
    }
}

/**
 * API key validation against a static list or shared dictionary.
 *
 * nginx.conf:
 *   location /api/ {
 *       auth_request /apikey_check;
 *       auth_request_set $api_client $upstream_http_x_api_client;
 *       proxy_pass http://backend;
 *   }
 *   location = /apikey_check {
 *       internal;
 *       js_content auth.validateApiKey;
 *   }
 */
function validateApiKey(r) {
    let apiKey = r.headersIn['X-API-Key'] || r.args.api_key || '';

    if (!apiKey) {
        r.return(401, JSON.stringify({
            error: 'API key required',
            hint: 'Pass via X-API-Key header or ?api_key= parameter'
        }));
        return;
    }

    // In production, look up from shared dict, Redis, or external store
    let validKeys = {
        'prod-key-abc-123': { client: 'service-a', tier: 'premium' },
        'prod-key-def-456': { client: 'service-b', tier: 'basic' },
        'prod-key-ghi-789': { client: 'service-c', tier: 'premium' },
    };

    let keyInfo = validKeys[apiKey];

    if (!keyInfo) {
        r.return(403, JSON.stringify({ error: 'Invalid API key' }));
        return;
    }

    r.headersOut['X-API-Client'] = keyInfo.client;
    r.headersOut['X-API-Tier'] = keyInfo.tier;
    r.return(200);
}

export default { validateJWT, jwtSubject, validateApiKey };
