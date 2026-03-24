# jq Cookbook

> 50+ real-world recipes organized by category. Each recipe includes the
> problem statement, input example, jq command, and expected output.

---

## Table of Contents

- [API Responses](#api-responses)
- [Config Files](#config-files)
- [Log Parsing](#log-parsing)
- [Data Migration](#data-migration)
- [Reporting & Aggregation](#reporting--aggregation)
- [Kubernetes Manifests](#kubernetes-manifests)
- [Terraform State](#terraform-state)
- [GitHub API](#github-api)
- [AWS CLI Output](#aws-cli-output)
- [Docker Inspect](#docker-inspect)
- [General Purpose](#general-purpose)

---

## API Responses

### 1. Extract paginated results into a single array

```bash
# Collect all pages of an API response
for page in $(seq 1 10); do
  curl -s "https://api.example.com/items?page=$page"
done | jq -s '[.[].items[]]'
```

### 2. Handle API error responses gracefully

```bash
curl -s "$API_URL" | jq '
  if .error then
    "Error \(.error.code): \(.error.message)" | halt_error(1)
  else
    .data
  end
'
```

### 3. Parse Link header for pagination

```bash
# Extract next page URL from response headers
curl -si "$API_URL" | grep -i '^link:' | \
  grep -oP '(?<=<)[^>]+(?=>; rel="next")'
```

### 4. Flatten nested API response

```bash
# API returns: {"data":{"users":{"edges":[{"node":{"name":"alice"}}]}}}
jq '[.data.users.edges[].node]'
```

### 5. Transform REST response to CSV

```bash
curl -s "$API_URL/users" | jq -r '
  ["id","name","email"],
  (.[] | [.id, .name, .email])
  | @csv
'
```

### 6. Merge responses from multiple endpoints

```bash
jq -n --slurpfile users <(curl -s "$API/users") \
      --slurpfile roles <(curl -s "$API/roles") '
  INDEX($roles[]; .id) as $roles
  | $users[]
  | . + {role_name: $roles[.role_id].name}
'
```

### 7. OAuth token extraction

```bash
TOKEN=$(curl -s -X POST "$AUTH_URL" \
  -d "grant_type=client_credentials" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" | \
  jq -r '.access_token')
```

### 8. Webhook payload construction

```bash
jq -n \
  --arg text "Deployment complete" \
  --arg channel "#deploys" \
  --arg emoji ":rocket:" \
  '{text: $text, channel: $channel, icon_emoji: $emoji}'
```

---

## Config Files

### 9. Merge config with environment overrides

```bash
jq -s '.[0] * .[1]' defaults.json overrides.json
```

### 10. Deep merge multiple config files

```bash
jq -s 'reduce .[] as $c ({}; . * $c)' \
  base.json env-dev.json local.json
```

### 11. Set nested config value

```bash
jq '.database.connection.pool_size = 20' config.json
```

### 12. Toggle feature flag

```bash
jq '.features.dark_mode = true' config.json > tmp && mv tmp config.json
```

### 13. Remove sensitive fields before committing

```bash
jq 'walk(if type == "object" then del(.password, .secret, .api_key, .token) else . end)' \
  config.json
```

### 14. Validate config has required fields

```bash
jq '
  ["host","port","database"] as $required
  | $required - keys
  | if length > 0 then
      "Missing required fields: \(. | join(", "))" | halt_error(1)
    else
      "Config valid" | halt_error(0)
    end
' config.json
```

### 15. Generate .env from JSON config

```bash
jq -r 'to_entries[] | "\(.key | ascii_upcase)=\(.value)"' config.json > .env
```

### 16. Convert env vars to JSON config

```bash
env | grep '^APP_' | jq -Rs '
  split("\n")
  | map(select(length > 0) | split("=") | {(.[0]): .[1:]|join("=")})
  | add
'
```

---

## Log Parsing

### 17. Parse JSON log lines and filter by level

```bash
jq -c 'select(.level == "error" or .level == "fatal")' app.jsonl
```

### 18. Extract error messages with timestamps

```bash
jq -r 'select(.level == "error") | "\(.timestamp) \(.message)"' app.jsonl
```

### 19. Count log entries by level

```bash
jq -s 'group_by(.level) | map({level: .[0].level, count: length})' app.jsonl
```

### 20. Find most frequent error messages

```bash
jq -s '
  map(select(.level == "error"))
  | group_by(.message)
  | map({message: .[0].message, count: length})
  | sort_by(-.count)
  | limit(10; .[])
' app.jsonl
```

### 21. Time-range filter for logs

```bash
jq --arg start "2024-01-01T00:00:00Z" --arg end "2024-01-02T00:00:00Z" '
  select(.timestamp >= $start and .timestamp < $end)
' app.jsonl
```

### 22. Extract unique request IDs from error logs

```bash
jq -r 'select(.level == "error") | .request_id' app.jsonl | sort -u
```

### 23. Calculate request duration percentiles

```bash
jq -s '
  map(.duration_ms) | sort
  | {
      p50: .[length * 0.5 | floor],
      p90: .[length * 0.9 | floor],
      p95: .[length * 0.95 | floor],
      p99: .[length * 0.99 | floor],
      max: last
    }
' request_logs.jsonl
```

---

## Data Migration

### 24. Rename fields across all records

```bash
jq 'map(.full_name = .name | .email_address = .email | del(.name, .email))' \
  old_format.json
```

### 25. Add default values for new fields

```bash
jq 'map(. + {status: (.status // "active"), version: (.version // 1)})' \
  records.json
```

### 26. Split full name into first/last

```bash
jq 'map(.name | split(" ") | {first: .[0], last: .[1:] | join(" ")})' \
  users.json
```

### 27. Convert date formats

```bash
# ISO 8601 to epoch
jq 'map(.created_at |= (sub("Z$"; "+00:00") | fromdate))' records.json

# Epoch to ISO 8601
jq 'map(.created_at |= todate)' records.json
```

### 28. Deduplicate records by key

```bash
jq 'group_by(.email) | map(max_by(.updated_at))' records.json
```

### 29. Normalize inconsistent data

```bash
jq 'map(
  .status |= ascii_downcase
  | .email |= ascii_downcase
  | .phone |= gsub("[^0-9+]"; "")
  | .name |= gsub("\\s+"; " ") | .name |= gsub("^\\s|\\s$"; "")
)' messy_data.json
```

### 30. Migrate nested structure to flat

```bash
jq 'map({
  id,
  name,
  street: .address.street,
  city: .address.city,
  zip: .address.zip,
  phone: (.contacts | map(select(.type=="phone")) | first | .value),
  email: (.contacts | map(select(.type=="email")) | first | .value)
})' old_format.json
```

---

## Reporting & Aggregation

### 31. Group and sum by category

```bash
jq '
  group_by(.category)
  | map({
      category: .[0].category,
      total: map(.amount) | add,
      count: length,
      avg: (map(.amount) | add / length)
    })
  | sort_by(-.total)
' transactions.json
```

### 32. Running total / cumulative sum

```bash
jq '
  reduce .[] as $x ([];
    . + [($x + (if length > 0 then last else 0 end))]
  )
' <<< '[10,20,30,40]'
# [10,30,60,100]
```

### 33. Generate a frequency histogram

```bash
jq '
  group_by(.score / 10 | floor * 10)
  | map({
      range: "\(.[0].score / 10 | floor * 10)-\(.[0].score / 10 | floor * 10 + 9)",
      count: length,
      bar: ("█" * length)
    })
' scores.json
```

### 34. Pivot data for cross-tabulation

```bash
jq '
  group_by(.region)
  | map({
      region: .[0].region,
      products: (group_by(.product) | map({(.[0].product): (map(.sales) | add)}) | add)
    })
' sales.json
```

### 35. Top N by field

```bash
jq 'sort_by(-.revenue) | [limit(10; .[])]' companies.json
```

### 36. Year-over-year comparison

```bash
jq '
  group_by(.year)
  | map({year: .[0].year, total: map(.revenue) | add})
  | sort_by(.year)
  | [range(1; length) as $i | {
      year: .[$i].year,
      total: .[$i].total,
      yoy_pct: (((.[$i].total - .[$i-1].total) / .[$i-1].total) * 100 | round)
    }]
' revenue_by_year.json
```

---

## Kubernetes Manifests

### 37. List all container images in a cluster

```bash
kubectl get pods -A -o json | jq -r '
  [.items[] | .spec.containers[] | .image]
  | unique
  | .[]
'
```

### 38. Find pods not in Running state

```bash
kubectl get pods -A -o json | jq -r '
  .items[]
  | select(.status.phase != "Running")
  | "\(.metadata.namespace)/\(.metadata.name): \(.status.phase)"
'
```

### 39. Get resource requests/limits summary

```bash
kubectl get pods -o json | jq '
  [.items[] | .spec.containers[] | {
    name: .name,
    cpu_req: .resources.requests.cpu,
    cpu_lim: .resources.limits.cpu,
    mem_req: .resources.requests.memory,
    mem_lim: .resources.limits.memory
  }]
'
```

### 40. Find containers without resource limits

```bash
kubectl get pods -A -o json | jq -r '
  .items[]
  | .metadata as $meta
  | .spec.containers[]
  | select(.resources.limits == null)
  | "\($meta.namespace)/\($meta.name): \(.name)"
'
```

### 41. Extract all ConfigMap keys and sizes

```bash
kubectl get configmaps -A -o json | jq '
  [.items[] | {
    namespace: .metadata.namespace,
    name: .metadata.name,
    keys: (.data // {} | keys),
    total_size: (.data // {} | to_entries | map(.value | length) | add // 0)
  }]
'
```

### 42. Generate environment patch from ConfigMap

```bash
kubectl get configmap myconfig -o json | jq '
  .data | to_entries | map({
    name: .key,
    valueFrom: {configMapKeyRef: {name: "myconfig", key: .key}}
  })
'
```

---

## Terraform State

### 43. List all resources with types

```bash
jq -r '.resources[] | "\(.type).\(.name)"' terraform.tfstate
```

### 44. Find all resources of a specific type

```bash
jq '.resources[] | select(.type == "aws_instance") | .instances[] | .attributes' \
  terraform.tfstate
```

### 45. Extract all output values

```bash
jq '.outputs | to_entries[] | "\(.key) = \(.value.value)"' terraform.tfstate
```

### 46. Compare resource counts between states

```bash
jq -s '
  map(.resources | group_by(.type) | map({type: .[0].type, count: length}))
  | transpose
  | map(select(length == 2))
  | map({
      type: .[0].type,
      before: .[0].count,
      after: .[1].count,
      diff: (.[1].count - .[0].count)
    })
  | map(select(.diff != 0))
' old-state.json new-state.json
```

### 47. Find resources with specific tags

```bash
jq '
  [.resources[]
   | .instances[]
   | select(.attributes.tags? and (.attributes.tags | has("Environment")))
   | {type: .attributes.id, env: .attributes.tags.Environment}]
' terraform.tfstate
```

### 48. Generate import commands from state

```bash
jq -r '
  .resources[]
  | .type as $type
  | .name as $name
  | .instances[]
  | "terraform import \($type).\($name) \(.attributes.id)"
' terraform.tfstate
```

---

## GitHub API

### 49. List repos with stars and language

```bash
curl -s "https://api.github.com/users/$USER/repos?per_page=100" | jq '
  map({name, stars: .stargazers_count, lang: .language})
  | sort_by(-.stars)
'
```

### 50. Get PR review status summary

```bash
gh api "repos/$OWNER/$REPO/pulls" --paginate | jq '
  map({
    number,
    title,
    author: .user.login,
    reviews: (.requested_reviewers | length),
    labels: [.labels[].name]
  })
'
```

### 51. Find stale branches (no commits in 90 days)

```bash
gh api "repos/$OWNER/$REPO/branches" --paginate | jq --arg cutoff \
  "$(date -d '90 days ago' -u +%Y-%m-%dT%H:%M:%SZ)" '
  map(select(.commit.commit.committer.date < $cutoff))
  | map({name, last_commit: .commit.commit.committer.date})
'
```

### 52. Aggregate issue labels across repo

```bash
gh api "repos/$OWNER/$REPO/issues?state=open&per_page=100" --paginate | jq '
  [.[].labels[].name]
  | group_by(.)
  | map({label: .[0], count: length})
  | sort_by(-.count)
'
```

### 53. Release changelog: commits between tags

```bash
gh api "repos/$OWNER/$REPO/compare/v1.0.0...v1.1.0" | jq -r '
  .commits[]
  | "- \(.commit.message | split("\n")[0]) (@\(.author.login))"
'
```

---

## AWS CLI Output

### 54. List EC2 instances with name and state

```bash
aws ec2 describe-instances | jq -r '
  .Reservations[].Instances[]
  | {
      id: .InstanceId,
      name: (.Tags // [] | map(select(.Key == "Name")) | first | .Value // "unnamed"),
      state: .State.Name,
      type: .InstanceType,
      az: .Placement.AvailabilityZone
    }
' | jq -s 'sort_by(.name)'
```

### 55. Find unattached EBS volumes

```bash
aws ec2 describe-volumes | jq '
  [.Volumes[] | select(.Attachments | length == 0) | {
    id: .VolumeId,
    size: "\(.Size)GB",
    type: .VolumeType,
    created: .CreateTime
  }]
'
```

### 56. Calculate total S3 bucket sizes

```bash
for bucket in $(aws s3api list-buckets | jq -r '.Buckets[].Name'); do
  aws cloudwatch get-metric-statistics \
    --namespace AWS/S3 --metric-name BucketSizeBytes \
    --dimensions Name=BucketName,Value="$bucket" Name=StorageType,Value=StandardStorage \
    --start-time "$(date -d '1 day ago' -u +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 86400 --statistics Maximum | \
    jq --arg bucket "$bucket" '{bucket: $bucket, bytes: .Datapoints[0].Maximum}'
done | jq -s 'sort_by(-.bytes)'
```

### 57. Security group audit: find open ports

```bash
aws ec2 describe-security-groups | jq '
  [.SecurityGroups[]
   | .GroupName as $name
   | .IpPermissions[]
   | select(.IpRanges[]?.CidrIp == "0.0.0.0/0")
   | {group: $name, port: (.FromPort // "all"), proto: .IpProtocol}
  ]
'
```

### 58. Lambda functions by runtime

```bash
aws lambda list-functions | jq '
  .Functions
  | group_by(.Runtime)
  | map({runtime: .[0].Runtime, count: length, functions: map(.FunctionName)})
  | sort_by(-.count)
'
```

---

## Docker Inspect

### 59. Get container IP addresses

```bash
docker inspect $(docker ps -q) | jq -r '
  .[]
  | "\(.Name[1:]): \(.NetworkSettings.Networks | to_entries[0].value.IPAddress)"
'
```

### 60. Find containers with exposed ports

```bash
docker inspect $(docker ps -q) | jq '
  [.[] | {
    name: .Name[1:],
    ports: (.NetworkSettings.Ports | to_entries | map(select(.value != null)) |
            map("\(.key) -> \(.value[0].HostPort)"))
  } | select(.ports | length > 0)]
'
```

### 61. Environment variable audit

```bash
docker inspect $(docker ps -q) | jq '
  [.[] | {
    container: .Name[1:],
    env: (.Config.Env | map(split("=") | {(.[0]): .[1:] | join("=")}) | add)
  }]
'
```

### 62. Container resource usage summary

```bash
docker inspect $(docker ps -q) | jq '
  [.[] | {
    name: .Name[1:],
    cpu_shares: .HostConfig.CpuShares,
    memory_limit: (.HostConfig.Memory / 1048576 | floor | tostring + "MB"),
    restart_policy: .HostConfig.RestartPolicy.Name,
    restart_count: .RestartCount
  }]
'
```

### 63. Diff two container configs

```bash
diff <(docker inspect container1 | jq '.[0].Config' -S) \
     <(docker inspect container2 | jq '.[0].Config' -S)
```

---

## General Purpose

### 64. Validate JSON files in a directory

```bash
find . -name '*.json' -exec sh -c '
  if ! jq empty "$1" 2>/dev/null; then
    echo "INVALID: $1" >&2
  fi
' _ {} \;
```

### 65. Pretty-print with custom indentation

```bash
jq --indent 4 '.' data.json      # 4-space indent
jq --tab '.' data.json            # tab indent
jq -c '.' data.json               # no indent (compact)
```

### 66. Convert JSON to YAML-like readable format

```bash
jq -r '
  paths(scalars) as $p
  | ($p | map(tostring) | join(".")) + " = " + (getpath($p) | tostring)
' data.json
```

### 67. Create JSON from CSV

```bash
# Input: name,age,city\nalice,30,NYC\nbob,25,LA
jq -Rs '
  split("\n") | map(select(length > 0))
  | .[0] as $headers
  | .[1:]
  | map(
      split(",")
      | [$headers | split(","), .] | transpose
      | map({(.[0]): .[1]}) | add
    )
' data.csv
```

### 68. Diff two JSON files (structural)

```bash
diff <(jq -S '.' a.json) <(jq -S '.' b.json)

# Show only changed paths and values
jq -n --slurpfile a a.json --slurpfile b b.json '
  def diff(a; b):
    (a | paths(scalars)) as $p
    | select(a | getpath($p)) as $av
    | select(b | getpath($p)) as $bv
    | select($av != $bv)
    | {path: ($p | join(".")), before: $av, after: $bv};
  [diff($a[0]; $b[0])]
'
```

### 69. Batch update: add timestamp to all records

```bash
jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   'map(. + {updated_at: $ts})' records.json
```

### 70. Generate SQL INSERT statements from JSON

```bash
jq -r '
  .[]
  | "INSERT INTO users (name, email, age) VALUES (" +
    ([.name, .email] | map("'"'"'" + . + "'"'"'") | join(", ")) +
    ", " + (.age | tostring) + ");"
' users.json
```

### 71. JSON Schema-like type summary

```bash
jq '
  def type_summary:
    if type == "object" then
      to_entries | map({(.key): (.value | type_summary)}) | add // {}
    elif type == "array" then
      if length > 0 then ["array<" + (.[0] | type) + ">"]
      else ["array<empty>"]
      end
    else type
    end;
  type_summary
' data.json
```

### 72. Streaming JSON pretty-printer for logs

```bash
# Continuously pretty-print NDJSON from a streaming source
tail -f app.jsonl | while IFS= read -r line; do
  echo "$line" | jq -C '.' 2>/dev/null || echo "$line"
done
```

### 73. Base64 decode a JWT token payload

```bash
echo "$JWT" | jq -R '
  split(".")[1]
  | @base64d
  | fromjson
  | {sub, exp: (.exp | todate), iat: (.iat | todate)}
'
```
