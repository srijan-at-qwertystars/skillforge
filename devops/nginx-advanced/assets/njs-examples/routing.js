// njs Routing Examples
// Demonstrates dynamic upstream selection, content-based routing, and A/B testing
// Usage: js_import router from routing.js; in nginx.conf
// Requires: load_module modules/ngx_http_js_module.so;

/**
 * Select upstream based on tenant header.
 *
 * nginx.conf:
 *   js_set $tenant_upstream router.tenantRoute;
 *   location /api/ {
 *       proxy_pass http://$tenant_upstream;
 *   }
 */
function tenantRoute(r) {
    let tenantId = r.headersIn['X-Tenant-ID'] || 'default';

    let routes = {
        'acme':    '10.0.1.10:8080',
        'globex':  '10.0.2.10:8080',
        'initech': '10.0.3.10:8080',
        'default': '10.0.0.10:8080'
    };

    return routes[tenantId] || routes['default'];
}

/**
 * Route based on API version from Accept header.
 * Accept: application/vnd.myapi.v2+json
 *
 * nginx.conf:
 *   js_set $api_upstream router.apiVersionRoute;
 *   location /api/ {
 *       proxy_pass http://$api_upstream;
 *   }
 */
function apiVersionRoute(r) {
    let accept = r.headersIn['Accept'] || '';
    let versionMatch = accept.match(/vnd\.myapi\.v(\d+)/);
    let version = versionMatch ? parseInt(versionMatch[1]) : 1;

    let backends = {
        1: 'api_v1_backend',
        2: 'api_v2_backend',
        3: 'api_v3_backend'
    };

    return backends[version] || backends[1];
}

/**
 * Route based on request body content (e.g., priority field).
 * Reads and parses JSON body to make routing decisions.
 *
 * nginx.conf:
 *   location /api/tasks {
 *       js_content router.bodyBasedRoute;
 *   }
 */
function bodyBasedRoute(r) {
    let body;
    try {
        body = JSON.parse(r.requestText || '{}');
    } catch (e) {
        r.return(400, JSON.stringify({ error: 'Invalid JSON body' }));
        return;
    }

    let upstream;
    if (body.priority === 'critical') {
        upstream = 'priority_backend';
    } else if (body.type === 'batch') {
        upstream = 'batch_backend';
    } else {
        upstream = 'default_backend';
    }

    r.internalRedirect(`/@route_${upstream}`);
}

/**
 * Geographic routing based on Accept-Language header.
 *
 * nginx.conf:
 *   js_set $geo_upstream router.geoRoute;
 */
function geoRoute(r) {
    let lang = (r.headersIn['Accept-Language'] || 'en').toLowerCase();

    if (lang.startsWith('de') || lang.startsWith('fr') || lang.startsWith('es')) {
        return 'eu_backend';
    } else if (lang.startsWith('ja') || lang.startsWith('zh') || lang.startsWith('ko')) {
        return 'asia_backend';
    }

    return 'us_backend';
}

/**
 * Canary routing: route a percentage of traffic to canary upstream.
 * Uses a hash of the client IP for deterministic assignment.
 *
 * nginx.conf:
 *   js_set $canary_upstream router.canaryRoute;
 *   location / {
 *       proxy_pass http://$canary_upstream;
 *       proxy_set_header X-Canary $canary_upstream;
 *   }
 */
function canaryRoute(r) {
    let canaryPercent = 5;  // 5% to canary
    let ip = r.remoteAddress;

    // Simple hash for deterministic routing
    let hash = 0;
    for (let i = 0; i < ip.length; i++) {
        hash = ((hash << 5) - hash) + ip.charCodeAt(i);
        hash = hash & hash;  // Convert to 32-bit integer
    }

    let bucket = Math.abs(hash) % 100;

    // Allow header override for testing
    if (r.headersIn['X-Force-Canary'] === 'true') {
        return 'canary_backend';
    }

    return bucket < canaryPercent ? 'canary_backend' : 'production_backend';
}

export default { tenantRoute, apiVersionRoute, bodyBasedRoute, geoRoute, canaryRoute };
