# 100 Essential jq One-Liners

> Copy-paste ready. Organized by task. Each one-liner is self-contained.

---

## Table of Contents

- [Pretty-Printing & Validation](#pretty-printing--validation)
- [Field Access & Extraction](#field-access--extraction)
- [Array Operations](#array-operations)
- [Filtering & Selection](#filtering--selection)
- [String Manipulation](#string-manipulation)
- [Object Operations](#object-operations)
- [Aggregation & Math](#aggregation--math)
- [Sorting & Grouping](#sorting--grouping)
- [Type Conversions](#type-conversions)
- [Data Reshaping](#data-reshaping)
- [Dates & Times](#dates--times)
- [File Operations](#file-operations)
- [API & Curl](#api--curl)
- [DevOps & Infrastructure](#devops--infrastructure)

---

## Pretty-Printing & Validation

```bash
# 1. Pretty-print JSON
jq '.' file.json

# 2. Compact JSON to single line
jq -c '.' file.json

# 3. Validate JSON (exit code 0 = valid)
jq empty file.json

# 4. Sort all keys alphabetically
jq -S '.' file.json

# 5. Pretty-print with tab indentation
jq --tab '.' file.json

# 6. Color output in terminal
jq -C '.' file.json

# 7. Validate all JSON files in directory
find . -name '*.json' -exec jq empty {} \; 2>&1
```

## Field Access & Extraction

```bash
# 8. Get a single field
jq '.name' file.json

# 9. Get nested field
jq '.user.address.city' file.json

# 10. Get multiple fields as new object
jq '{name, email}' file.json

# 11. Get field with default for missing
jq '.name // "unknown"' file.json

# 12. Get field value as raw string (no quotes)
jq -r '.name' file.json

# 13. Get field from each array element
jq '.[].name' file.json

# 14. Safe nested access (no errors on missing)
jq '.user?.profile?.name? // "N/A"' file.json

# 15. Get value at dynamic path
jq 'getpath(["users",0,"name"])' file.json
```

## Array Operations

```bash
# 16. Get array length
jq 'length' file.json

# 17. Get first element
jq '.[0]' file.json

# 18. Get last element
jq '.[-1]' file.json

# 19. Get slice
jq '.[2:5]' file.json

# 20. Reverse array
jq 'reverse' file.json

# 21. Flatten nested arrays
jq 'flatten' file.json

# 22. Get unique values
jq 'unique' file.json

# 23. Remove duplicates by field
jq 'unique_by(.email)' file.json

# 24. Concatenate two arrays
jq -s '.[0] + .[1]' a.json b.json

# 25. Check if array contains value
jq 'any(. == "target")' file.json

# 26. Array intersection
jq -n --argjson a '[1,2,3]' --argjson b '[2,3,4]' '[$a[] | select(IN($b[]))]'

# 27. Array difference
jq -n --argjson a '[1,2,3]' --argjson b '[2,3,4]' '[$a[] | select(IN($b[]) | not)]'

# 28. Chunk array into groups of N
jq '[range(0;length;3) as $i | .[$i:$i+3]]' file.json

# 29. Zip two arrays
jq -n --argjson a '["x","y"]' --argjson b '[1,2]' '[$a, $b] | transpose | map({(.[0]): .[1]}) | add'
```

## Filtering & Selection

```bash
# 30. Filter by field value
jq '.[] | select(.status == "active")' file.json

# 31. Filter by numeric comparison
jq '[.[] | select(.age >= 18)]' file.json

# 32. Filter by regex
jq '.[] | select(.email | test("@gmail\\.com$"))' file.json

# 33. Filter nulls out
jq '[.[] | select(. != null)]' file.json

# 34. Filter objects with specific key
jq '[.[] | select(has("email"))]' file.json

# 35. Filter by multiple conditions
jq '[.[] | select(.active and .score > 80)]' file.json

# 36. Negative filter (exclude)
jq '[.[] | select(.role != "admin")]' file.json

# 37. First match only
jq 'first(.[] | select(.type == "error"))' file.json

# 38. Limit results
jq '[limit(5; .[] | select(.active))]' file.json
```

## String Manipulation

```bash
# 39. String length
jq '.name | length' file.json

# 40. Uppercase / lowercase
jq '.name | ascii_upcase' file.json
jq '.name | ascii_downcase' file.json

# 41. Split string
jq '.path | split("/")' file.json

# 42. Join array to string
jq '.tags | join(", ")' file.json

# 43. String replace (regex)
jq '.text | gsub("old"; "new")' file.json

# 44. Trim prefix / suffix
jq '.url | ltrimstr("https://")' file.json
jq '.file | rtrimstr(".json")' file.json

# 45. String interpolation
jq -r '"Name: \(.name), Age: \(.age)"' file.json

# 46. Pad string to width
jq -r '.name | . + " " * (20 - length)' file.json

# 47. Extract regex captures
jq '.line | capture("(?<ip>[0-9.]+).*(?<code>[0-9]{3})")' file.json

# 48. Base64 encode/decode
echo '"hello"' | jq '@base64'
echo '"aGVsbG8="' | jq '@base64d'
```

## Object Operations

```bash
# 49. Get all keys
jq 'keys' file.json

# 50. Get all values
jq 'values' file.json

# 51. Check if key exists
jq 'has("name")' file.json

# 52. Add/update field
jq '. + {"new_field": "value"}' file.json

# 53. Delete field
jq 'del(.password)' file.json

# 54. Delete multiple fields
jq 'del(.password, .secret, .token)' file.json

# 55. Rename field
jq '.full_name = .name | del(.name)' file.json

# 56. Pick specific fields
jq '{name, email}' file.json

# 57. Omit specific fields (keep everything else)
jq 'del(.internal, .debug)' file.json

# 58. Merge two objects
jq -s '.[0] * .[1]' a.json b.json

# 59. Convert object to key-value pairs
jq 'to_entries' file.json

# 60. Transform all keys
jq 'with_entries(.key |= ascii_downcase)' file.json

# 61. Filter object by key pattern
jq 'with_entries(select(.key | startswith("user_")))' file.json

# 62. Count keys
jq 'keys | length' file.json
```

## Aggregation & Math

```bash
# 63. Sum numbers
jq '[.[].amount] | add' file.json

# 64. Average
jq '[.[].score] | add / length' file.json

# 65. Min / Max
jq '[.[].price] | min' file.json
jq '[.[].price] | max' file.json

# 66. Min/Max by field
jq 'min_by(.price)' file.json
jq 'max_by(.score)' file.json

# 67. Count elements
jq '[.[] | select(.active)] | length' file.json

# 68. Running total
jq '[foreach .[] as $x (0; . + $x)]' file.json

# 69. Standard deviation
jq '[.[].v] | (add/length) as $m | map(pow(. - $m;2)) | add/length | sqrt' file.json

# 70. Percentage of total
jq '(map(.v) | add) as $t | map(. + {pct: (.v / $t * 100 | round)})' file.json
```

## Sorting & Grouping

```bash
# 71. Sort array
jq 'sort' file.json

# 72. Sort by field
jq 'sort_by(.name)' file.json

# 73. Sort descending
jq 'sort_by(-.score)' file.json

# 74. Group by field
jq 'group_by(.category)' file.json

# 75. Group and count
jq 'group_by(.status) | map({status: .[0].status, count: length})' file.json

# 76. Group and sum
jq 'group_by(.dept) | map({dept: .[0].dept, total: map(.salary) | add})' file.json

# 77. Top N by field
jq 'sort_by(-.score) | .[0:10]' file.json

# 78. Find duplicates
jq 'group_by(.email) | map(select(length > 1))' file.json

# 79. Frequency table
jq '[.[].category] | group_by(.) | map({value: .[0], count: length}) | sort_by(-.count)' file.json
```

## Type Conversions

```bash
# 80. Number to string
jq '.count | tostring' file.json

# 81. String to number
jq '.port | tonumber' file.json

# 82. To JSON string
jq '.data | tojson' file.json

# 83. From JSON string
jq '.json_str | fromjson' file.json

# 84. Array of objects to CSV
jq -r '(.[0] | keys_unsorted) as $k | $k, (.[] | [.[$k[]]] | map(tostring)) | @csv' file.json

# 85. Epoch to ISO date
jq '.ts | todate' file.json

# 86. Boolean to string
jq 'if .active then "yes" else "no" end' file.json
```

## Data Reshaping

```bash
# 87. Flatten nested object to dot-paths
jq '[paths(scalars) as $p | {([$p[]|tostring]|join(".")): getpath($p)}] | add' file.json

# 88. Array of objects to lookup object
jq 'INDEX(.id)' file.json

# 89. Transpose (rows ↔ columns)
jq 'transpose' file.json

# 90. Object → array of {key, value}
jq 'to_entries' file.json

# 91. Array → object (pairs)
jq 'from_entries' file.json

# 92. Pivot: long → wide
jq 'group_by(.date) | map({date: .[0].date} + (map({(.k): .v}) | add))' file.json

# 93. Invert map (swap keys/values)
jq 'to_entries | map({key: (.value|tostring), value: .key}) | from_entries' file.json
```

## Dates & Times

```bash
# 94. Current timestamp (ISO 8601)
jq -n 'now | todate'

# 95. Current Unix epoch
jq -n 'now'

# 96. Format date
jq -n 'now | strftime("%Y-%m-%d %H:%M:%S")'

# 97. Parse ISO date to epoch
jq '.date | fromdateiso8601' file.json
```

## File Operations

```bash
# 98. Modify JSON file in place
jq '.version = "2.0"' f.json > tmp.$$.json && mv tmp.$$.json f.json

# 99. Merge multiple JSON files
jq -s 'reduce .[] as $x ({}; . * $x)' *.json

# 100. Generate JSON from shell vars
jq -n --arg h "$HOSTNAME" --argjson p "${PORT:-8080}" '{host:$h, port:$p}'
```

## API & Curl

```bash
# 101 (bonus). Pretty-print API response
curl -s https://api.example.com/data | jq '.'

# 102 (bonus). Extract field from API
curl -s https://api.github.com/users/octocat | jq -r '.name'

# 103 (bonus). POST with jq-built body
curl -s -X POST "$URL" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg u "$USER" '{user: $u}')"
```

## DevOps & Infrastructure

```bash
# 104 (bonus). List Kubernetes pod names
kubectl get pods -o json | jq -r '.items[].metadata.name'

# 105 (bonus). Terraform resource count by type
jq '.resources | group_by(.type) | map({type:.[0].type, n:length})' terraform.tfstate

# 106 (bonus). Docker container IPs
docker inspect $(docker ps -q) | jq -r '.[] | "\(.Name[1:]): \(.NetworkSettings.IPAddress)"'

# 107 (bonus). AWS EC2 instance names
aws ec2 describe-instances | jq -r '.Reservations[].Instances[] | (.Tags//[]|map(select(.Key=="Name"))[0].Value // "unnamed") + " " + .InstanceId'
```
