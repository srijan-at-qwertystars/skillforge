#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# index-lifecycle-setup.sh
#
# Creates ILM (Index Lifecycle Management) policies, component templates, and
# composable index templates for common observability use cases:
#   - logs    : hot → warm → cold → delete
#   - metrics : hot → warm → delete
#   - apm     : hot → warm → cold → delete
#
# Prerequisites:
#   - curl
#   - Elasticsearch 7.x / 8.x with ILM enabled
#
# Usage:
#   ./index-lifecycle-setup.sh --url http://localhost:9200
#   ./index-lifecycle-setup.sh --url https://localhost:9200 --user elastic --password secret
#   ./index-lifecycle-setup.sh --help
#
# Flags:
#   --url        Elasticsearch URL (default: http://localhost:9200)
#   --user       Username for authentication (optional)
#   --password   Password for authentication (optional)
#   --help       Show this help message
###############################################################################

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
ES_URL="http://localhost:9200"
ES_USER=""
ES_PASSWORD=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

SUCCESS_COUNT=0
FAILURE_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { printf "${RED}ERROR: %s${RESET}\n" "$*" >&2; exit 1; }

usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Create ILM policies, component templates, and index templates."
    echo ""
    echo "Options:"
    echo "  --url        Elasticsearch URL (default: http://localhost:9200)"
    echo "  --user       Username for authentication"
    echo "  --password   Password for authentication"
    echo "  --help       Show this help message"
    exit 0
}

section() {
    echo ""
    printf "${CYAN}${BOLD}── %s ─────────────────────────────────────────────${RESET}\n" "$1"
}

# Build reusable curl arguments
build_curl_args() {
    CURL_ARGS=(-s -S --max-time 30)
    if [[ -n "$ES_USER" && -n "$ES_PASSWORD" ]]; then
        CURL_ARGS+=(-u "${ES_USER}:${ES_PASSWORD}")
    fi
    if [[ "$ES_URL" == https://* ]]; then
        CURL_ARGS+=(--cacert /dev/null -k)
    fi
}

# PUT a JSON body to Elasticsearch and report success/failure.
#   $1 = human-readable label
#   $2 = API path (e.g. /_ilm/policy/logs-policy)
#   $3 = JSON body
es_put() {
    local label="$1" path="$2" body="$3"
    local http_code response

    response=$(curl "${CURL_ARGS[@]}" -w "\n%{http_code}" \
        -X PUT "${ES_URL}${path}" \
        -H 'Content-Type: application/json' \
        -d "$body" 2>&1) || true

    http_code=$(echo "$response" | tail -n1)
    local resp_body
    resp_body=$(echo "$response" | sed '$d')

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        printf "  ${GREEN}✓${RESET} %s  ${GREEN}(HTTP %s)${RESET}\n" "$label" "$http_code"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        printf "  ${RED}✗${RESET} %s  ${RED}(HTTP %s)${RESET}\n" "$label" "$http_code"
        printf "    %s\n" "$resp_body"
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)
                ES_URL="${2:?'--url requires a value'}"
                shift 2
                ;;
            --user)
                ES_USER="${2:?'--user requires a value'}"
                shift 2
                ;;
            --password)
                ES_PASSWORD="${2:?'--password requires a value'}"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# ILM Policies
# ---------------------------------------------------------------------------
create_ilm_policies() {
    section "ILM Policies"

    # --- logs-policy ---
    es_put "logs-policy" "/_ilm/policy/logs-policy" '{
        "policy": {
            "phases": {
                "hot": {
                    "min_age": "0ms",
                    "actions": {
                        "rollover": {
                            "max_primary_shard_size": "30gb",
                            "max_age": "1d"
                        },
                        "set_priority": {
                            "priority": 100
                        }
                    }
                },
                "warm": {
                    "min_age": "7d",
                    "actions": {
                        "shrink": {
                            "number_of_shards": 1
                        },
                        "forcemerge": {
                            "max_num_segments": 1
                        },
                        "set_priority": {
                            "priority": 50
                        },
                        "allocate": {
                            "number_of_replicas": 1
                        }
                    }
                },
                "cold": {
                    "min_age": "30d",
                    "actions": {
                        "set_priority": {
                            "priority": 0
                        },
                        "allocate": {
                            "number_of_replicas": 0
                        }
                    }
                },
                "delete": {
                    "min_age": "90d",
                    "actions": {
                        "delete": {}
                    }
                }
            }
        }
    }'

    # --- metrics-policy ---
    es_put "metrics-policy" "/_ilm/policy/metrics-policy" '{
        "policy": {
            "phases": {
                "hot": {
                    "min_age": "0ms",
                    "actions": {
                        "rollover": {
                            "max_primary_shard_size": "50gb",
                            "max_age": "1d"
                        },
                        "set_priority": {
                            "priority": 100
                        }
                    }
                },
                "warm": {
                    "min_age": "3d",
                    "actions": {
                        "set_priority": {
                            "priority": 50
                        },
                        "allocate": {
                            "number_of_replicas": 1
                        }
                    }
                },
                "delete": {
                    "min_age": "30d",
                    "actions": {
                        "delete": {}
                    }
                }
            }
        }
    }'

    # --- apm-policy ---
    es_put "apm-policy" "/_ilm/policy/apm-policy" '{
        "policy": {
            "phases": {
                "hot": {
                    "min_age": "0ms",
                    "actions": {
                        "rollover": {
                            "max_primary_shard_size": "20gb",
                            "max_age": "1d"
                        },
                        "set_priority": {
                            "priority": 100
                        }
                    }
                },
                "warm": {
                    "min_age": "3d",
                    "actions": {
                        "set_priority": {
                            "priority": 50
                        },
                        "allocate": {
                            "number_of_replicas": 1
                        }
                    }
                },
                "cold": {
                    "min_age": "14d",
                    "actions": {
                        "set_priority": {
                            "priority": 0
                        },
                        "allocate": {
                            "number_of_replicas": 0
                        }
                    }
                },
                "delete": {
                    "min_age": "30d",
                    "actions": {
                        "delete": {}
                    }
                }
            }
        }
    }'
}

# ---------------------------------------------------------------------------
# Component Templates
# ---------------------------------------------------------------------------
create_component_templates() {
    section "Component Templates"

    # --- logs-mappings ---
    es_put "logs-mappings" "/_component_template/logs-mappings" '{
        "template": {
            "mappings": {
                "dynamic": "true",
                "properties": {
                    "@timestamp": {
                        "type": "date"
                    },
                    "message": {
                        "type": "text",
                        "fields": {
                            "keyword": {
                                "type": "keyword",
                                "ignore_above": 2048
                            }
                        }
                    },
                    "log.level": {
                        "type": "keyword"
                    },
                    "host.name": {
                        "type": "keyword"
                    },
                    "service.name": {
                        "type": "keyword"
                    },
                    "trace.id": {
                        "type": "keyword"
                    },
                    "span.id": {
                        "type": "keyword"
                    }
                }
            }
        }
    }'

    # --- logs-settings ---
    es_put "logs-settings" "/_component_template/logs-settings" '{
        "template": {
            "settings": {
                "index": {
                    "number_of_shards": 1,
                    "number_of_replicas": 1,
                    "lifecycle": {
                        "name": "logs-policy",
                        "rollover_alias": "logs"
                    },
                    "codec": "best_compression",
                    "refresh_interval": "5s"
                }
            }
        }
    }'

    # --- metrics-mappings ---
    es_put "metrics-mappings" "/_component_template/metrics-mappings" '{
        "template": {
            "mappings": {
                "dynamic": "true",
                "properties": {
                    "@timestamp": {
                        "type": "date"
                    },
                    "host.name": {
                        "type": "keyword"
                    },
                    "service.name": {
                        "type": "keyword"
                    },
                    "metric.name": {
                        "type": "keyword"
                    },
                    "metric.value": {
                        "type": "double"
                    },
                    "metric.unit": {
                        "type": "keyword"
                    },
                    "labels": {
                        "type": "object",
                        "dynamic": true
                    }
                }
            }
        }
    }'

    # --- metrics-settings ---
    es_put "metrics-settings" "/_component_template/metrics-settings" '{
        "template": {
            "settings": {
                "index": {
                    "number_of_shards": 1,
                    "number_of_replicas": 1,
                    "lifecycle": {
                        "name": "metrics-policy",
                        "rollover_alias": "metrics"
                    },
                    "codec": "best_compression",
                    "refresh_interval": "10s"
                }
            }
        }
    }'

    # --- apm-mappings ---
    es_put "apm-mappings" "/_component_template/apm-mappings" '{
        "template": {
            "mappings": {
                "dynamic": "true",
                "properties": {
                    "@timestamp": {
                        "type": "date"
                    },
                    "trace.id": {
                        "type": "keyword"
                    },
                    "span.id": {
                        "type": "keyword"
                    },
                    "parent.id": {
                        "type": "keyword"
                    },
                    "transaction.id": {
                        "type": "keyword"
                    },
                    "transaction.name": {
                        "type": "keyword"
                    },
                    "transaction.type": {
                        "type": "keyword"
                    },
                    "transaction.duration.us": {
                        "type": "long"
                    },
                    "service.name": {
                        "type": "keyword"
                    },
                    "service.version": {
                        "type": "keyword"
                    },
                    "service.environment": {
                        "type": "keyword"
                    },
                    "error.message": {
                        "type": "text"
                    },
                    "error.type": {
                        "type": "keyword"
                    }
                }
            }
        }
    }'

    # --- apm-settings ---
    es_put "apm-settings" "/_component_template/apm-settings" '{
        "template": {
            "settings": {
                "index": {
                    "number_of_shards": 1,
                    "number_of_replicas": 1,
                    "lifecycle": {
                        "name": "apm-policy",
                        "rollover_alias": "apm"
                    },
                    "codec": "best_compression",
                    "refresh_interval": "5s"
                }
            }
        }
    }'
}

# ---------------------------------------------------------------------------
# Index Templates
# ---------------------------------------------------------------------------
create_index_templates() {
    section "Index Templates"

    # --- logs index template ---
    es_put "logs (index template)" "/_index_template/logs" '{
        "index_patterns": ["logs-*"],
        "composed_of": ["logs-mappings", "logs-settings"],
        "priority": 200,
        "data_stream": {},
        "_meta": {
            "description": "Index template for application and system logs with ILM"
        }
    }'

    # --- metrics index template ---
    es_put "metrics (index template)" "/_index_template/metrics" '{
        "index_patterns": ["metrics-*"],
        "composed_of": ["metrics-mappings", "metrics-settings"],
        "priority": 200,
        "data_stream": {},
        "_meta": {
            "description": "Index template for infrastructure and application metrics with ILM"
        }
    }'

    # --- apm index template ---
    es_put "apm (index template)" "/_index_template/apm" '{
        "index_patterns": ["apm-*"],
        "composed_of": ["apm-mappings", "apm-settings"],
        "priority": 200,
        "data_stream": {},
        "_meta": {
            "description": "Index template for APM traces and transactions with ILM"
        }
    }'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    printf "${BOLD}── Summary ───────────────────────────────────────────${RESET}\n"
    printf "  ${GREEN}Succeeded : %d${RESET}\n" "$SUCCESS_COUNT"

    if [[ "$FAILURE_COUNT" -gt 0 ]]; then
        printf "  ${RED}Failed    : %d${RESET}\n" "$FAILURE_COUNT"
    else
        printf "  Failed    : %d\n" "$FAILURE_COUNT"
    fi

    echo ""

    if [[ "$FAILURE_COUNT" -gt 0 ]]; then
        printf "${YELLOW}Some operations failed. Review the output above for details.${RESET}\n\n"
        exit 1
    else
        printf "${GREEN}All ILM policies, component templates, and index templates created successfully.${RESET}\n\n"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    build_curl_args

    echo ""
    printf "${BOLD}Elasticsearch ILM & Template Setup${RESET}\n"
    printf "Target: ${CYAN}%s${RESET}\n" "$ES_URL"
    printf "Time  : %s\n" "$(date +'%Y-%m-%dT%H:%M:%S%z')"

    create_ilm_policies
    create_component_templates
    create_index_templates
    print_summary
}

main "$@"
