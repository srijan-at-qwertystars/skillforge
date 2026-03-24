// njs Request/Response Transformation Examples
// Demonstrates body transformation, header manipulation, and response filtering
// Usage: js_import transform from transform.js; in nginx.conf
// Requires: load_module modules/ngx_http_js_module.so;

/**
 * Generate a unique request ID for distributed tracing.
 *
 * nginx.conf:
 *   js_set $trace_id transform.generateTraceId;
 *   proxy_set_header X-Trace-ID $trace_id;
 */
function generateTraceId(r) {
    let existing = r.headersIn['X-Trace-ID'];
    if (existing) return existing;

    let timestamp = Date.now().toString(36);
    let random = Math.random().toString(36).substring(2, 10);
    return `${timestamp}-${random}`;
}

/**
 * Enrich request with metadata before forwarding to upstream.
 * Adds computed headers based on request properties.
 *
 * nginx.conf:
 *   location /api/ {
 *       js_content transform.enrichRequest;
 *   }
 */
function enrichRequest(r) {
    // Classify the request
    let contentType = r.headersIn['Content-Type'] || '';
    let isJson = contentType.includes('application/json');
    let isFormData = contentType.includes('multipart/form-data');

    // Detect client type
    let ua = r.headersIn['User-Agent'] || '';
    let clientType = 'unknown';
    if (/Mobile|Android|iPhone/i.test(ua)) clientType = 'mobile';
    else if (/Mozilla|Chrome|Safari|Firefox/i.test(ua)) clientType = 'browser';
    else if (/curl|wget|python|java|go-http/i.test(ua)) clientType = 'api-client';

    // Forward with enriched headers
    r.subrequest('/upstream' + r.uri, {
        method: r.method,
        body: r.requestText,
        args: r.variables.args,
    }, function(reply) {
        // Copy upstream response
        for (let h in reply.headersOut) {
            r.headersOut[h] = reply.headersOut[h];
        }
        r.headersOut['X-Client-Type'] = clientType;
        r.headersOut['X-Content-Class'] = isJson ? 'json' : isFormData ? 'form' : 'other';
        r.return(reply.status, reply.responseText);
    });
}

/**
 * Filter sensitive data from JSON responses.
 * Redacts fields like passwords, tokens, SSN, etc.
 *
 * nginx.conf:
 *   location /api/ {
 *       proxy_pass http://backend;
 *       js_body_filter transform.redactSensitive;
 *   }
 */
function redactSensitive(r, data, flags) {
    let contentType = r.headersOut['Content-Type'] || '';
    if (!contentType.includes('application/json')) {
        r.sendBuffer(data, flags);
        return;
    }

    // Accumulate response body
    if (!r._body) r._body = '';
    r._body += data;

    if (flags.last) {
        try {
            let json = JSON.parse(r._body);
            let sensitiveKeys = new Set([
                'password', 'passwd', 'secret', 'token', 'access_token',
                'refresh_token', 'api_key', 'apikey', 'ssn', 'credit_card',
                'card_number', 'cvv', 'pin'
            ]);

            function redact(obj) {
                if (Array.isArray(obj)) {
                    return obj.map(item => redact(item));
                }
                if (obj && typeof obj === 'object') {
                    let result = {};
                    for (let key in obj) {
                        if (sensitiveKeys.has(key.toLowerCase())) {
                            result[key] = '[REDACTED]';
                        } else {
                            result[key] = redact(obj[key]);
                        }
                    }
                    return result;
                }
                return obj;
            }

            let filtered = JSON.stringify(redact(json));
            r.sendBuffer(filtered, flags);
        } catch (e) {
            r.sendBuffer(r._body, flags);
        }
    }
}

/**
 * Transform XML response to JSON.
 * Simple XML-to-JSON converter for proxied legacy APIs.
 *
 * nginx.conf:
 *   location /legacy-api/ {
 *       proxy_pass http://legacy_backend;
 *       js_body_filter transform.xmlToJson;
 *       proxy_set_header Accept "application/xml";
 *   }
 */
function xmlToJson(r, data, flags) {
    let contentType = r.headersOut['Content-Type'] || '';
    if (!contentType.includes('xml')) {
        r.sendBuffer(data, flags);
        return;
    }

    if (!r._body) r._body = '';
    r._body += data;

    if (flags.last) {
        // Simple XML tag extraction (for basic key-value XML)
        let result = {};
        let tagPattern = /<(\w+)>([^<]*)<\/\1>/g;
        let match;

        while ((match = tagPattern.exec(r._body)) !== null) {
            let key = match[1];
            let value = match[2];
            // Try to parse numbers
            if (/^\d+$/.test(value)) value = parseInt(value);
            else if (/^\d+\.\d+$/.test(value)) value = parseFloat(value);
            else if (value === 'true') value = true;
            else if (value === 'false') value = false;
            result[key] = value;
        }

        r.headersOut['Content-Type'] = 'application/json';
        r.sendBuffer(JSON.stringify(result), flags);
    }
}

/**
 * Add CORS headers dynamically based on allowed origins list.
 *
 * nginx.conf:
 *   location /api/ {
 *       proxy_pass http://backend;
 *       js_header_filter transform.addCorsHeaders;
 *   }
 */
function addCorsHeaders(r) {
    let origin = r.headersIn['Origin'] || '';
    let allowedOrigins = [
        'https://app.example.com',
        'https://staging.example.com',
        'https://admin.example.com'
    ];
    let allowedPattern = /^https:\/\/.*\.example\.com$/;

    if (allowedOrigins.includes(origin) || allowedPattern.test(origin)) {
        r.headersOut['Access-Control-Allow-Origin'] = origin;
        r.headersOut['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE, PATCH, OPTIONS';
        r.headersOut['Access-Control-Allow-Headers'] = 'Authorization, Content-Type, X-Request-ID';
        r.headersOut['Access-Control-Allow-Credentials'] = 'true';
        r.headersOut['Access-Control-Max-Age'] = '86400';
        r.headersOut['Vary'] = 'Origin';
    }
}

export default { generateTraceId, enrichRequest, redactSensitive, xmlToJson, addCorsHeaders };
