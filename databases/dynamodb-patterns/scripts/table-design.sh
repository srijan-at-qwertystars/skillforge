#!/usr/bin/env bash
#
# table-design.sh — Interactive CLI to scaffold a DynamoDB table definition
#
# Usage:
#   ./table-design.sh
#   ./table-design.sh --output cfn       # Output CloudFormation YAML (default)
#   ./table-design.sh --output cdk       # Output CDK TypeScript
#   ./table-design.sh --output terraform  # Output Terraform HCL
#   ./table-design.sh --non-interactive --table-name MyTable --pk PK --pk-type S --sk SK --sk-type S
#
# The script interactively prompts for:
#   - Table name
#   - Primary key (partition key + optional sort key)
#   - Billing mode (on-demand or provisioned)
#   - Global Secondary Indexes (GSIs)
#   - TTL configuration
#   - Stream specification
#   - Point-in-time recovery
#   - Tags
#
# Output is written to stdout. Redirect to a file:
#   ./table-design.sh > my-table.yaml
#
# Requirements: bash 4+, no external dependencies
#

set -euo pipefail

# Defaults
OUTPUT_FORMAT="cfn"
NON_INTERACTIVE=false
TABLE_NAME=""
PK_NAME=""
PK_TYPE="S"
SK_NAME=""
SK_TYPE="S"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --output) OUTPUT_FORMAT="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --table-name) TABLE_NAME="$2"; shift 2 ;;
        --pk) PK_NAME="$2"; shift 2 ;;
        --pk-type) PK_TYPE="$2"; shift 2 ;;
        --sk) SK_NAME="$2"; shift 2 ;;
        --sk-type) SK_TYPE="$2"; shift 2 ;;
        -h|--help)
            head -25 "$0" | tail -20
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Input helpers ---

prompt() {
    local var_name="$1" prompt_text="$2" default="${3:-}"
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        eval "$var_name=\"$default\""
        return
    fi
    if [[ -n "$default" ]]; then
        read -rp "$prompt_text [$default]: " value
        eval "$var_name=\"${value:-$default}\""
    else
        read -rp "$prompt_text: " value
        eval "$var_name=\"$value\""
    fi
}

prompt_yn() {
    local var_name="$1" prompt_text="$2" default="${3:-n}"
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        eval "$var_name=\"$default\""
        return
    fi
    read -rp "$prompt_text [y/n] ($default): " value
    value="${value:-$default}"
    eval "$var_name=\"$value\""
}

type_name() {
    case "$1" in
        S) echo "String" ;;
        N) echo "Number" ;;
        B) echo "Binary" ;;
        *) echo "$1" ;;
    esac
}

# --- Gather inputs ---

echo "=== DynamoDB Table Designer ===" >&2
echo "" >&2

# Table name
if [[ -z "$TABLE_NAME" ]]; then
    prompt TABLE_NAME "Table name" "MyTable"
fi

# Partition key
if [[ -z "$PK_NAME" ]]; then
    prompt PK_NAME "Partition key attribute name" "PK"
    prompt PK_TYPE "Partition key type (S=String, N=Number, B=Binary)" "S"
fi

# Sort key
if [[ -z "$SK_NAME" ]]; then
    prompt_yn HAS_SK "Add a sort key?" "y"
    if [[ "$HAS_SK" == "y" ]]; then
        prompt SK_NAME "Sort key attribute name" "SK"
        prompt SK_TYPE "Sort key type (S/N/B)" "S"
    fi
fi

# Billing mode
prompt BILLING_MODE "Billing mode (ondemand/provisioned)" "ondemand"

RCU=5
WCU=5
if [[ "$BILLING_MODE" == "provisioned" ]]; then
    prompt RCU "Read capacity units (RCU)" "5"
    prompt WCU "Write capacity units (WCU)" "5"
fi

# GSIs
declare -a GSI_NAMES=()
declare -a GSI_PKS=()
declare -a GSI_PK_TYPES=()
declare -a GSI_SKS=()
declare -a GSI_SK_TYPES=()
declare -a GSI_PROJECTIONS=()

prompt_yn ADD_GSI "Add Global Secondary Indexes?" "y"
while [[ "$ADD_GSI" == "y" ]]; do
    gsi_idx=${#GSI_NAMES[@]}
    prompt gsi_name "GSI name" "GSI$((gsi_idx + 1))"
    prompt gsi_pk "GSI partition key" "GSI$((gsi_idx + 1))PK"
    prompt gsi_pk_type "GSI partition key type (S/N/B)" "S"
    prompt gsi_sk "GSI sort key (leave empty for none)" "GSI$((gsi_idx + 1))SK"
    prompt gsi_proj "Projection type (ALL/KEYS_ONLY/INCLUDE)" "ALL"

    GSI_NAMES+=("$gsi_name")
    GSI_PKS+=("$gsi_pk")
    GSI_PK_TYPES+=("$gsi_pk_type")
    GSI_SKS+=("$gsi_sk")
    GSI_SK_TYPES+=("S")
    GSI_PROJECTIONS+=("$gsi_proj")

    prompt_yn ADD_GSI "Add another GSI?" "n"
done

# TTL
prompt_yn ENABLE_TTL "Enable TTL?" "y"
TTL_ATTR="ttl"
if [[ "$ENABLE_TTL" == "y" ]]; then
    prompt TTL_ATTR "TTL attribute name" "ttl"
fi

# Streams
prompt_yn ENABLE_STREAMS "Enable DynamoDB Streams?" "y"
STREAM_VIEW="NEW_AND_OLD_IMAGES"
if [[ "$ENABLE_STREAMS" == "y" ]]; then
    prompt STREAM_VIEW "Stream view type (KEYS_ONLY/NEW_IMAGE/OLD_IMAGE/NEW_AND_OLD_IMAGES)" "NEW_AND_OLD_IMAGES"
fi

# PITR
prompt_yn ENABLE_PITR "Enable Point-in-Time Recovery?" "y"

echo "" >&2
echo "Generating $OUTPUT_FORMAT template..." >&2

# --- CloudFormation output ---

generate_cfn() {
    cat <<EOF
AWSTemplateFormatVersion: '2010-09-09'
Description: DynamoDB table - ${TABLE_NAME}

Resources:
  ${TABLE_NAME}Table:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: ${TABLE_NAME}
      BillingMode: $([ "$BILLING_MODE" == "ondemand" ] && echo "PAY_PER_REQUEST" || echo "PROVISIONED")
      AttributeDefinitions:
        - AttributeName: ${PK_NAME}
          AttributeType: ${PK_TYPE}
EOF

    if [[ -n "$SK_NAME" ]]; then
        cat <<EOF
        - AttributeName: ${SK_NAME}
          AttributeType: ${SK_TYPE}
EOF
    fi

    # Add GSI attribute definitions
    declare -A seen_attrs
    seen_attrs["$PK_NAME"]=1
    [[ -n "$SK_NAME" ]] && seen_attrs["$SK_NAME"]=1

    for i in "${!GSI_NAMES[@]}"; do
        if [[ -z "${seen_attrs[${GSI_PKS[$i]}]:-}" ]]; then
            echo "        - AttributeName: ${GSI_PKS[$i]}"
            echo "          AttributeType: ${GSI_PK_TYPES[$i]}"
            seen_attrs["${GSI_PKS[$i]}"]=1
        fi
        if [[ -n "${GSI_SKS[$i]}" && -z "${seen_attrs[${GSI_SKS[$i]}]:-}" ]]; then
            echo "        - AttributeName: ${GSI_SKS[$i]}"
            echo "          AttributeType: ${GSI_SK_TYPES[$i]}"
            seen_attrs["${GSI_SKS[$i]}"]=1
        fi
    done

    cat <<EOF
      KeySchema:
        - AttributeName: ${PK_NAME}
          KeyType: HASH
EOF

    if [[ -n "$SK_NAME" ]]; then
        cat <<EOF
        - AttributeName: ${SK_NAME}
          KeyType: RANGE
EOF
    fi

    if [[ "$BILLING_MODE" == "provisioned" ]]; then
        cat <<EOF
      ProvisionedThroughput:
        ReadCapacityUnits: ${RCU}
        WriteCapacityUnits: ${WCU}
EOF
    fi

    # GSIs
    if [[ ${#GSI_NAMES[@]} -gt 0 ]]; then
        echo "      GlobalSecondaryIndexes:"
        for i in "${!GSI_NAMES[@]}"; do
            cat <<EOF
        - IndexName: ${GSI_NAMES[$i]}
          KeySchema:
            - AttributeName: ${GSI_PKS[$i]}
              KeyType: HASH
EOF
            if [[ -n "${GSI_SKS[$i]}" ]]; then
                cat <<EOF
            - AttributeName: ${GSI_SKS[$i]}
              KeyType: RANGE
EOF
            fi
            cat <<EOF
          Projection:
            ProjectionType: ${GSI_PROJECTIONS[$i]}
EOF
            if [[ "$BILLING_MODE" == "provisioned" ]]; then
                cat <<EOF
          ProvisionedThroughput:
            ReadCapacityUnits: ${RCU}
            WriteCapacityUnits: ${WCU}
EOF
            fi
        done
    fi

    if [[ "$ENABLE_TTL" == "y" ]]; then
        cat <<EOF
      TimeToLiveSpecification:
        AttributeName: ${TTL_ATTR}
        Enabled: true
EOF
    fi

    if [[ "$ENABLE_STREAMS" == "y" ]]; then
        cat <<EOF
      StreamSpecification:
        StreamViewType: ${STREAM_VIEW}
EOF
    fi

    if [[ "$ENABLE_PITR" == "y" ]]; then
        cat <<EOF
      PointInTimeRecoverySpecification:
        PointInTimeRecoveryEnabled: true
EOF
    fi

    cat <<EOF
      Tags:
        - Key: Environment
          Value: production
        - Key: ManagedBy
          Value: cloudformation

Outputs:
  TableName:
    Value: !Ref ${TABLE_NAME}Table
  TableArn:
    Value: !GetAtt ${TABLE_NAME}Table.Arn
EOF

    if [[ "$ENABLE_STREAMS" == "y" ]]; then
        cat <<EOF
  StreamArn:
    Value: !GetAtt ${TABLE_NAME}Table.StreamArn
EOF
    fi
}

# --- CDK output ---

generate_cdk() {
    cat <<EOF
import * as cdk from 'aws-cdk-lib';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import { Construct } from 'constructs';

export class ${TABLE_NAME}Stack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const table = new dynamodb.Table(this, '${TABLE_NAME}Table', {
      tableName: '${TABLE_NAME}',
      partitionKey: {
        name: '${PK_NAME}',
        type: dynamodb.AttributeType.$([ "$PK_TYPE" == "S" ] && echo "STRING" || ([ "$PK_TYPE" == "N" ] && echo "NUMBER" || echo "BINARY")),
      },
EOF

    if [[ -n "$SK_NAME" ]]; then
        cat <<EOF
      sortKey: {
        name: '${SK_NAME}',
        type: dynamodb.AttributeType.$([ "$SK_TYPE" == "S" ] && echo "STRING" || ([ "$SK_TYPE" == "N" ] && echo "NUMBER" || echo "BINARY")),
      },
EOF
    fi

    if [[ "$BILLING_MODE" == "ondemand" ]]; then
        echo "      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,"
    else
        echo "      billingMode: dynamodb.BillingMode.PROVISIONED,"
        echo "      readCapacity: ${RCU},"
        echo "      writeCapacity: ${WCU},"
    fi

    if [[ "$ENABLE_STREAMS" == "y" ]]; then
        echo "      stream: dynamodb.StreamViewType.${STREAM_VIEW},"
    fi

    if [[ "$ENABLE_PITR" == "y" ]]; then
        echo "      pointInTimeRecovery: true,"
    fi

    echo "      removalPolicy: cdk.RemovalPolicy.RETAIN,"
    echo "    });"
    echo ""

    if [[ "$ENABLE_TTL" == "y" ]]; then
        echo "    table.addTimeToLive({ attributeName: '${TTL_ATTR}' });"
        echo ""
    fi

    for i in "${!GSI_NAMES[@]}"; do
        cat <<EOF
    table.addGlobalSecondaryIndex({
      indexName: '${GSI_NAMES[$i]}',
      partitionKey: {
        name: '${GSI_PKS[$i]}',
        type: dynamodb.AttributeType.STRING,
      },
EOF
        if [[ -n "${GSI_SKS[$i]}" ]]; then
            cat <<EOF
      sortKey: {
        name: '${GSI_SKS[$i]}',
        type: dynamodb.AttributeType.STRING,
      },
EOF
        fi
        echo "      projectionType: dynamodb.ProjectionType.${GSI_PROJECTIONS[$i]},"
        echo "    });"
        echo ""
    done

    cat <<EOF
    new cdk.CfnOutput(this, 'TableName', { value: table.tableName });
    new cdk.CfnOutput(this, 'TableArn', { value: table.tableArn });
  }
}
EOF
}

# --- Terraform output ---

generate_terraform() {
    cat <<EOF
resource "aws_dynamodb_table" "${TABLE_NAME}" {
  name         = "${TABLE_NAME}"
  billing_mode = "$([ "$BILLING_MODE" == "ondemand" ] && echo "PAY_PER_REQUEST" || echo "PROVISIONED")"
EOF

    if [[ "$BILLING_MODE" == "provisioned" ]]; then
        echo "  read_capacity  = ${RCU}"
        echo "  write_capacity = ${WCU}"
    fi

    echo ""
    echo "  hash_key  = \"${PK_NAME}\""
    [[ -n "$SK_NAME" ]] && echo "  range_key = \"${SK_NAME}\""
    echo ""

    echo "  attribute {"
    echo "    name = \"${PK_NAME}\""
    echo "    type = \"${PK_TYPE}\""
    echo "  }"

    if [[ -n "$SK_NAME" ]]; then
        echo "  attribute {"
        echo "    name = \"${SK_NAME}\""
        echo "    type = \"${SK_TYPE}\""
        echo "  }"
    fi

    declare -A seen_attrs
    seen_attrs["$PK_NAME"]=1
    [[ -n "$SK_NAME" ]] && seen_attrs["$SK_NAME"]=1

    for i in "${!GSI_NAMES[@]}"; do
        if [[ -z "${seen_attrs[${GSI_PKS[$i]}]:-}" ]]; then
            echo "  attribute {"
            echo "    name = \"${GSI_PKS[$i]}\""
            echo "    type = \"${GSI_PK_TYPES[$i]}\""
            echo "  }"
            seen_attrs["${GSI_PKS[$i]}"]=1
        fi
        if [[ -n "${GSI_SKS[$i]}" && -z "${seen_attrs[${GSI_SKS[$i]}]:-}" ]]; then
            echo "  attribute {"
            echo "    name = \"${GSI_SKS[$i]}\""
            echo "    type = \"S\""
            echo "  }"
            seen_attrs["${GSI_SKS[$i]}"]=1
        fi
    done

    for i in "${!GSI_NAMES[@]}"; do
        echo ""
        echo "  global_secondary_index {"
        echo "    name            = \"${GSI_NAMES[$i]}\""
        echo "    hash_key        = \"${GSI_PKS[$i]}\""
        [[ -n "${GSI_SKS[$i]}" ]] && echo "    range_key       = \"${GSI_SKS[$i]}\""
        echo "    projection_type = \"${GSI_PROJECTIONS[$i]}\""
        if [[ "$BILLING_MODE" == "provisioned" ]]; then
            echo "    read_capacity   = ${RCU}"
            echo "    write_capacity  = ${WCU}"
        fi
        echo "  }"
    done

    if [[ "$ENABLE_TTL" == "y" ]]; then
        echo ""
        echo "  ttl {"
        echo "    attribute_name = \"${TTL_ATTR}\""
        echo "    enabled        = true"
        echo "  }"
    fi

    if [[ "$ENABLE_STREAMS" == "y" ]]; then
        echo ""
        echo "  stream_enabled   = true"
        echo "  stream_view_type = \"${STREAM_VIEW}\""
    fi

    if [[ "$ENABLE_PITR" == "y" ]]; then
        echo ""
        echo "  point_in_time_recovery {"
        echo "    enabled = true"
        echo "  }"
    fi

    echo ""
    echo "  tags = {"
    echo "    Environment = \"production\""
    echo "    ManagedBy   = \"terraform\""
    echo "  }"
    echo "}"
}

# --- Generate output ---

case "$OUTPUT_FORMAT" in
    cfn|cloudformation) generate_cfn ;;
    cdk) generate_cdk ;;
    terraform|tf) generate_terraform ;;
    *) echo "Unknown format: $OUTPUT_FORMAT. Use: cfn, cdk, terraform" >&2; exit 1 ;;
esac
