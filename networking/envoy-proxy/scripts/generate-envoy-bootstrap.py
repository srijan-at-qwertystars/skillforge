#!/usr/bin/env python3
"""generate-envoy-bootstrap.py — Generate Envoy bootstrap configuration from CLI arguments.

Usage:
    ./generate-envoy-bootstrap.py --listener-port 8080 --cluster my_service \
        --upstream backend:8080 --admin-port 9901

    ./generate-envoy-bootstrap.py \
        --listener-port 8443 --listener-name https_listener \
        --cluster api --upstream api-host:8080 --upstream api-host2:8080 \
        --admin-port 9901 --admin-address 127.0.0.1 \
        --access-log /var/log/envoy/access.log \
        --tracing-cluster otel_collector --tracing-port 4317 \
        --lb-policy LEAST_REQUEST \
        --connect-timeout 1s \
        --enable-health-check --health-check-path /healthz \
        --xds-cluster xds_server --xds-address control-plane --xds-port 18000 \
        --output /etc/envoy/envoy.yaml

    ./generate-envoy-bootstrap.py --help

Output:
    Writes valid Envoy v3 bootstrap YAML to stdout or --output file.
"""

import argparse
import sys
import json
from collections import OrderedDict


def ordered_dict(*args):
    """Create an OrderedDict preserving insertion order for YAML output."""
    return OrderedDict(args)


def make_socket_address(address, port):
    return {
        "socket_address": {
            "address": address,
            "port_value": int(port),
        }
    }


def make_endpoint(address, port):
    return {
        "endpoint": {
            "address": make_socket_address(address, int(port)),
        }
    }


def make_cluster(name, upstreams, lb_policy="ROUND_ROBIN", connect_timeout="0.5s",
                 health_check_path=None, enable_http2=False):
    endpoints = []
    for upstream in upstreams:
        host, port = parse_host_port(upstream)
        endpoints.append(make_endpoint(host, port))

    cluster = OrderedDict()
    cluster["name"] = name
    cluster["connect_timeout"] = connect_timeout
    cluster["type"] = "STRICT_DNS"
    cluster["lb_policy"] = lb_policy
    cluster["load_assignment"] = {
        "cluster_name": name,
        "endpoints": [{"lb_endpoints": endpoints}],
    }

    if health_check_path:
        cluster["health_checks"] = [{
            "timeout": "1s",
            "interval": "5s",
            "unhealthy_threshold": 3,
            "healthy_threshold": 2,
            "http_health_check": {"path": health_check_path},
        }]

    if enable_http2:
        cluster["typed_extension_protocol_options"] = {
            "envoy.extensions.upstreams.http.v3.HttpProtocolOptions": {
                "@type": "type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions",
                "explicit_http_config": {
                    "http2_protocol_options": {}
                }
            }
        }

    return cluster


def make_listener(name, port, cluster_name, access_log_path=None, route_timeout=None):
    access_log = []
    if access_log_path:
        access_log.append({
            "name": "envoy.access_loggers.file",
            "typed_config": {
                "@type": "type.googleapis.com/envoy.extensions.access_loggers.file.v3.FileAccessLog",
                "path": access_log_path,
                "log_format": {
                    "json_format": {
                        "timestamp": "%START_TIME%",
                        "method": "%REQ(:METHOD)%",
                        "path": "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%",
                        "status": "%RESPONSE_CODE%",
                        "flags": "%RESPONSE_FLAGS%",
                        "duration_ms": "%DURATION%",
                        "upstream": "%UPSTREAM_HOST%",
                        "request_id": "%REQ(X-REQUEST-ID)%",
                    }
                },
            }
        })
    else:
        access_log.append({
            "name": "envoy.access_loggers.stdout",
            "typed_config": {
                "@type": "type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog",
            }
        })

    route_action = {"cluster": cluster_name}
    if route_timeout:
        route_action["timeout"] = route_timeout

    hcm_config = OrderedDict()
    hcm_config["@type"] = "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager"
    hcm_config["stat_prefix"] = "ingress"
    hcm_config["access_log"] = access_log
    hcm_config["route_config"] = {
        "name": "local_route",
        "virtual_hosts": [{
            "name": "default",
            "domains": ["*"],
            "routes": [{
                "match": {"prefix": "/"},
                "route": route_action,
            }],
        }],
    }
    hcm_config["http_filters"] = [{
        "name": "envoy.filters.http.router",
        "typed_config": {
            "@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router",
        }
    }]

    return {
        "name": name,
        "address": make_socket_address("0.0.0.0", port),
        "filter_chains": [{
            "filters": [{
                "name": "envoy.filters.network.http_connection_manager",
                "typed_config": hcm_config,
            }]
        }],
    }


def make_xds_config(xds_cluster, xds_address, xds_port, ads=False):
    """Generate dynamic_resources and xDS cluster."""
    xds_cluster_def = make_cluster(
        xds_cluster,
        [f"{xds_address}:{xds_port}"],
        connect_timeout="1s",
        enable_http2=True,
    )

    config_source = {
        "resource_api_version": "V3",
        "api_config_source": {
            "api_type": "GRPC",
            "transport_api_version": "V3",
            "grpc_services": [{
                "envoy_grpc": {"cluster_name": xds_cluster}
            }],
        }
    }

    if ads:
        ads_source = {
            "resource_api_version": "V3",
            "ads": {}
        }
        dynamic = OrderedDict()
        dynamic["ads_config"] = {
            "api_type": "GRPC",
            "transport_api_version": "V3",
            "grpc_services": [{
                "envoy_grpc": {"cluster_name": xds_cluster}
            }],
        }
        dynamic["lds_config"] = ads_source
        dynamic["cds_config"] = ads_source
    else:
        dynamic = OrderedDict()
        dynamic["lds_config"] = config_source
        dynamic["cds_config"] = config_source

    return dynamic, xds_cluster_def


def parse_host_port(s):
    """Parse 'host:port' string."""
    if ":" not in s:
        raise argparse.ArgumentTypeError(f"Invalid host:port format: '{s}'. Expected 'host:port'.")
    parts = s.rsplit(":", 1)
    return parts[0], int(parts[1])


def to_yaml(obj, indent=0):
    """Convert Python dict/list to YAML string without PyYAML dependency."""
    lines = []
    prefix = "  " * indent

    if isinstance(obj, dict):
        if not obj:
            return "{}"
        for key, value in obj.items():
            if isinstance(value, (dict, OrderedDict)):
                if not value:
                    lines.append(f"{prefix}{key}: {{}}")
                else:
                    lines.append(f"{prefix}{key}:")
                    lines.append(to_yaml(value, indent + 1))
            elif isinstance(value, list):
                if not value:
                    lines.append(f"{prefix}{key}: []")
                else:
                    lines.append(f"{prefix}{key}:")
                    for item in value:
                        if isinstance(item, (dict, OrderedDict)):
                            item_yaml = to_yaml(item, indent + 2)
                            item_lines = item_yaml.split("\n")
                            if item_lines:
                                lines.append(f"{prefix}  - {item_lines[0].strip()}")
                                for il in item_lines[1:]:
                                    if il.strip():
                                        lines.append(f"{prefix}    {il.strip()}")
                        else:
                            lines.append(f"{prefix}  - {format_value(item)}")
            else:
                lines.append(f"{prefix}{key}: {format_value(value)}")
    elif isinstance(obj, list):
        for item in obj:
            if isinstance(item, (dict, OrderedDict)):
                lines.append(f"{prefix}- ")
                lines.append(to_yaml(item, indent + 1))
            else:
                lines.append(f"{prefix}- {format_value(item)}")

    return "\n".join(lines)


def format_value(v):
    """Format a scalar value for YAML output."""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return str(v)
    s = str(v)
    # Quote strings that could be misinterpreted
    if s in ("true", "false", "null", "yes", "no", "on", "off", ""):
        return f'"{s}"'
    if s.startswith("{") or s.startswith("[") or s.startswith("*"):
        return f'"{s}"'
    if ":" in s and not s.startswith("type.googleapis.com"):
        return f'"{s}"'
    return s


def generate_bootstrap(args):
    """Generate the full bootstrap config."""
    config = OrderedDict()

    # Static resources
    static = OrderedDict()
    clusters = []

    # Main listener and cluster (only if not using xDS for everything)
    if args.cluster and args.upstream:
        listener = make_listener(
            name=args.listener_name,
            port=args.listener_port,
            cluster_name=args.cluster,
            access_log_path=args.access_log,
            route_timeout=args.route_timeout,
        )
        static["listeners"] = [listener]

        cluster = make_cluster(
            name=args.cluster,
            upstreams=args.upstream,
            lb_policy=args.lb_policy,
            connect_timeout=args.connect_timeout,
            health_check_path=args.health_check_path if args.enable_health_check else None,
        )
        clusters.append(cluster)

    # xDS configuration
    if args.xds_cluster:
        dynamic, xds_cluster_def = make_xds_config(
            args.xds_cluster, args.xds_address, args.xds_port, args.ads
        )
        config["dynamic_resources"] = dynamic
        clusters.append(xds_cluster_def)

    # Tracing cluster
    if args.tracing_cluster:
        tracing_cluster = make_cluster(
            name=args.tracing_cluster,
            upstreams=[f"{args.tracing_address}:{args.tracing_port}"],
            connect_timeout="1s",
            enable_http2=True,
        )
        clusters.append(tracing_cluster)

    if clusters:
        static["clusters"] = clusters

    if static:
        config["static_resources"] = static

    # Admin interface
    config["admin"] = {
        "address": make_socket_address(args.admin_address, args.admin_port),
    }

    # Node identity (for xDS)
    if args.node_id or args.node_cluster:
        node = OrderedDict()
        if args.node_id:
            node["id"] = args.node_id
        if args.node_cluster:
            node["cluster"] = args.node_cluster
        config["node"] = node

    return config


def main():
    parser = argparse.ArgumentParser(
        description="Generate Envoy bootstrap configuration from CLI arguments.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --listener-port 8080 --cluster my_svc --upstream backend:8080
  %(prog)s --listener-port 8080 --cluster api --upstream host1:8080 --upstream host2:8080 \\
           --lb-policy LEAST_REQUEST --enable-health-check --health-check-path /healthz
  %(prog)s --xds-cluster xds --xds-address control-plane --xds-port 18000 --ads
        """
    )

    # Listener
    parser.add_argument("--listener-port", type=int, default=8080,
                        help="Listener port (default: 8080)")
    parser.add_argument("--listener-name", default="main_listener",
                        help="Listener name (default: main_listener)")

    # Cluster / Upstream
    parser.add_argument("--cluster", help="Primary cluster name")
    parser.add_argument("--upstream", action="append", default=[],
                        help="Upstream host:port (can specify multiple)")
    parser.add_argument("--lb-policy", default="ROUND_ROBIN",
                        choices=["ROUND_ROBIN", "LEAST_REQUEST", "RING_HASH", "RANDOM", "MAGLEV"],
                        help="Load balancing policy (default: ROUND_ROBIN)")
    parser.add_argument("--connect-timeout", default="0.5s",
                        help="Upstream connect timeout (default: 0.5s)")
    parser.add_argument("--route-timeout", default=None,
                        help="Route-level request timeout (e.g., 30s)")

    # Health checks
    parser.add_argument("--enable-health-check", action="store_true",
                        help="Enable active health checking")
    parser.add_argument("--health-check-path", default="/healthz",
                        help="Health check HTTP path (default: /healthz)")

    # Admin
    parser.add_argument("--admin-port", type=int, default=9901,
                        help="Admin interface port (default: 9901)")
    parser.add_argument("--admin-address", default="127.0.0.1",
                        help="Admin interface bind address (default: 127.0.0.1)")

    # Access logs
    parser.add_argument("--access-log", default=None,
                        help="Access log file path (default: stdout)")

    # xDS
    parser.add_argument("--xds-cluster", default=None,
                        help="xDS control plane cluster name")
    parser.add_argument("--xds-address", default="localhost",
                        help="xDS control plane address (default: localhost)")
    parser.add_argument("--xds-port", type=int, default=18000,
                        help="xDS control plane port (default: 18000)")
    parser.add_argument("--ads", action="store_true",
                        help="Use Aggregated Discovery Service (ADS)")

    # Tracing
    parser.add_argument("--tracing-cluster", default=None,
                        help="Tracing collector cluster name")
    parser.add_argument("--tracing-address", default="localhost",
                        help="Tracing collector address (default: localhost)")
    parser.add_argument("--tracing-port", type=int, default=4317,
                        help="Tracing collector port (default: 4317)")

    # Node identity
    parser.add_argument("--node-id", default=None,
                        help="Envoy node ID (for xDS identification)")
    parser.add_argument("--node-cluster", default=None,
                        help="Envoy node cluster name (for xDS grouping)")

    # Output
    parser.add_argument("--output", "-o", default=None,
                        help="Output file path (default: stdout)")
    parser.add_argument("--json", action="store_true",
                        help="Output as JSON instead of YAML")

    args = parser.parse_args()

    if not args.cluster and not args.xds_cluster:
        parser.error("At least one of --cluster or --xds-cluster is required")

    if args.cluster and not args.upstream:
        parser.error("--upstream is required when --cluster is specified")

    config = generate_bootstrap(args)

    if args.json:
        output = json.dumps(config, indent=2)
    else:
        output = "# Envoy Bootstrap Configuration\n"
        output += "# Generated by generate-envoy-bootstrap.py\n"
        output += "#\n"
        output += to_yaml(config)

    if args.output:
        with open(args.output, "w") as f:
            f.write(output + "\n")
        print(f"Bootstrap config written to {args.output}", file=sys.stderr)
    else:
        print(output)


if __name__ == "__main__":
    main()
