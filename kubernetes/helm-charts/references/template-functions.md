# Helm Template Functions Reference

## Table of Contents

- [Go Template Basics](#go-template-basics)
- [Built-in Helm Functions](#built-in-helm-functions)
- [String Functions](#string-functions)
- [Math Functions](#math-functions)
- [Date Functions](#date-functions)
- [Default and Empty Functions](#default-and-empty-functions)
- [Encoding Functions](#encoding-functions)
- [Crypto Functions](#crypto-functions)
- [List Functions](#list-functions)
- [Dictionary Functions](#dictionary-functions)
- [Type Conversion Functions](#type-conversion-functions)
- [Flow Control](#flow-control)
- [Named Templates](#named-templates)
- [Path and File Functions](#path-and-file-functions)
- [Regex Functions](#regex-functions)
- [Semantic Version Functions](#semantic-version-functions)
- [UUID and Random Functions](#uuid-and-random-functions)
- [OS and Environment Functions](#os-and-environment-functions)
- [Common Helm Idioms](#common-helm-idioms)

---

## Go Template Basics

### Actions

```
{{ .Values.key }}              Access value
{{- .Values.key }}             Trim preceding whitespace
{{ .Values.key -}}             Trim trailing whitespace
{{- .Values.key -}}            Trim both sides
```

### Pipelines

```
{{ .Values.name | upper | quote }}     Chain functions left-to-right
{{ printf "%s-%s" .Release.Name "app" }}  Direct function call
```

### Variables

```
{{- $name := .Values.name -}}
{{- $fullname := printf "%s-%s" .Release.Name .Chart.Name -}}
{{ $name }}
```

### Comments

```
{{/* This is a comment — produces no output */}}
```

### Built-in Context Objects

| Object | Description |
|--------|-------------|
| `.Values` | Values from values.yaml + overrides |
| `.Chart` | Chart.yaml contents (`.Chart.Name`, `.Chart.Version`, `.Chart.AppVersion`) |
| `.Release` | Release info (`.Release.Name`, `.Release.Namespace`, `.Release.IsUpgrade`, `.Release.IsInstall`, `.Release.Revision`, `.Release.Service`) |
| `.Template` | Template info (`.Template.Name`, `.Template.BasePath`) |
| `.Files` | Access non-template files in chart |
| `.Capabilities` | Cluster capabilities (`.Capabilities.KubeVersion`, `.Capabilities.APIVersions`) |
| `$` | Root context (always points to the top-level scope) |

---

## Built-in Helm Functions

These are Helm-specific, not from Sprig:

| Function | Description | Example |
|----------|-------------|---------|
| `include` | Render named template as string (pipeable) | `{{ include "myapp.labels" . \| nindent 4 }}` |
| `required` | Fail rendering if value is empty | `{{ required "image.repo is required" .Values.image.repository }}` |
| `tpl` | Evaluate a string as a template | `{{ tpl .Values.customAnnotation . }}` |
| `toYaml` | Marshal to YAML string | `{{ toYaml .Values.resources \| nindent 6 }}` |
| `toJson` | Marshal to JSON string | `{{ toJson .Values.config }}` |
| `toToml` | Marshal to TOML string | `{{ toToml .Values.config }}` |
| `fromYaml` | Parse YAML string to object | `{{ $obj := fromYaml (.Files.Get "config.yaml") }}` |
| `fromJson` | Parse JSON string to object | `{{ $obj := fromJson (.Files.Get "config.json") }}` |
| `fromJsonArray` | Parse JSON array string | `{{ $arr := fromJsonArray (.Files.Get "list.json") }}` |
| `fromYamlArray` | Parse YAML array string | `{{ $arr := fromYamlArray (.Files.Get "list.yaml") }}` |
| `lookup` | Query live cluster resources | `{{ lookup "v1" "Secret" "ns" "name" }}` |

### `include` vs `template`

Always prefer `include` over `template`:

```yaml
# GOOD — output can be piped
labels:
  {{- include "myapp.labels" . | nindent 4 }}

# BAD — template cannot pipe output
labels:
  {{ template "myapp.labels" . }}   {{/* No nindent possible */}}
```

### `lookup` Details

```yaml
# Get specific resource — returns the object
{{ $secret := lookup "v1" "Secret" .Release.Namespace "my-secret" }}
{{- if $secret }}
existing: {{ index $secret.data "password" | b64dec }}
{{- end }}

# List resources — returns a list object
{{ $services := lookup "v1" "Service" .Release.Namespace "" }}
{{- range $services.items }}
- {{ .metadata.name }}
{{- end }}

# lookup returns empty dict during helm template (no cluster access)
```

### `.Files` Object

```yaml
# Read a file as string
{{ .Files.Get "config/app.conf" }}

# Read as bytes (for binary)
{{ .Files.GetBytes "bin/data" }}

# Glob files
{{ range $path, $content := .Files.Glob "configs/**.yaml" }}
{{ $path }}: |
{{ $content | indent 2 }}
{{ end }}

# As ConfigMap data
data:
  {{ (.Files.Glob "configs/*").AsConfig | nindent 2 }}

# As Secrets data (base64 encoded)
data:
  {{ (.Files.Glob "secrets/*").AsSecrets | nindent 2 }}

# File lines
{{ range .Files.Lines "config/hosts.txt" }}
- {{ . }}
{{ end }}
```

---

## String Functions

| Function | Description | Example | Result |
|----------|-------------|---------|--------|
| `trim` | Remove leading/trailing whitespace | `{{ " hello " \| trim }}` | `hello` |
| `trimAll` | Remove given chars from both ends | `{{ "**hello**" \| trimAll "*" }}` | `hello` |
| `trimPrefix` | Remove prefix | `{{ "hello-world" \| trimPrefix "hello-" }}` | `world` |
| `trimSuffix` | Remove suffix | `{{ "hello.txt" \| trimSuffix ".txt" }}` | `hello` |
| `upper` | Uppercase | `{{ "hello" \| upper }}` | `HELLO` |
| `lower` | Lowercase | `{{ "HELLO" \| lower }}` | `hello` |
| `title` | Title case | `{{ "hello world" \| title }}` | `Hello World` |
| `untitle` | Remove title case | `{{ "Hello World" \| untitle }}` | `hello world` |
| `repeat` | Repeat string N times | `{{ "ab" \| repeat 3 }}` | `ababab` |
| `substr` | Substring (start, end, string) | `{{ substr 0 5 "hello world" }}` | `hello` |
| `nospace` | Remove all whitespace | `{{ "h e l l o" \| nospace }}` | `hello` |
| `trunc` | Truncate to length | `{{ "hello world" \| trunc 5 }}` | `hello` |
| `abbrev` | Abbreviate with ellipsis | `{{ "hello world" \| abbrev 8 }}` | `hello...` |
| `abbrevboth` | Abbreviate both sides | `{{ abbrevboth 5 10 "1234 5678 9123" }}` | `...5678...` |
| `initials` | First letter of each word | `{{ "hello world" \| initials }}` | `HW` |
| `wrap` | Word wrap at column | `{{ "long text..." \| wrap 80 }}` | wrapped text |
| `wrapWith` | Word wrap with custom newline | `{{ "text" \| wrapWith 80 "\n\t" }}` | wrapped text |
| `contains` | Check if string contains substr | `{{ contains "ll" "hello" }}` | `true` |
| `hasPrefix` | Check prefix | `{{ hasPrefix "he" "hello" }}` | `true` |
| `hasSuffix` | Check suffix | `{{ hasSuffix "lo" "hello" }}` | `true` |
| `quote` | Wrap in double quotes | `{{ "hello" \| quote }}` | `"hello"` |
| `squote` | Wrap in single quotes | `{{ "hello" \| squote }}` | `'hello'` |
| `cat` | Concatenate with spaces | `{{ cat "hello" "world" }}` | `hello world` |
| `indent` | Indent every line | `{{ "a\nb" \| indent 4 }}` | `    a\n    b` |
| `nindent` | Newline + indent every line | `{{ "a\nb" \| nindent 4 }}` | `\n    a\n    b` |
| `replace` | Replace substring | `{{ "foo" \| replace "o" "0" }}` | `f00` |
| `plural` | Pluralize | `{{ 2 \| plural "item" "items" }}` | `items` |
| `snakecase` | Convert to snake_case | `{{ "FirstName" \| snakecase }}` | `first_name` |
| `camelcase` | Convert to CamelCase | `{{ "first_name" \| camelcase }}` | `FirstName` |
| `kebabcase` | Convert to kebab-case | `{{ "FirstName" \| kebabcase }}` | `first-name` |
| `swapcase` | Swap letter case | `{{ "Hello" \| swapcase }}` | `hELLO` |
| `shuffle` | Shuffle string chars | `{{ "hello" \| shuffle }}` | random order |

### String Formatting

```yaml
{{ printf "%s-%s" .Release.Name .Chart.Name }}
{{ printf "%d" .Values.port }}
{{ printf "%s:%d" .Values.host (.Values.port | int) }}
```

---

## Math Functions

| Function | Description | Example | Result |
|----------|-------------|---------|--------|
| `add` | Add | `{{ add 3 2 }}` | `5` |
| `sub` | Subtract | `{{ sub 5 2 }}` | `3` |
| `mul` | Multiply | `{{ mul 3 4 }}` | `12` |
| `div` | Integer divide | `{{ div 10 3 }}` | `3` |
| `mod` | Modulo | `{{ mod 10 3 }}` | `1` |
| `max` | Maximum | `{{ max 1 5 3 }}` | `5` |
| `min` | Minimum | `{{ min 1 5 3 }}` | `1` |
| `floor` | Floor | `{{ floor 3.7 }}` | `3` |
| `ceil` | Ceiling | `{{ ceil 3.2 }}` | `4` |
| `round` | Round to precision | `{{ round 3.145 2 }}` | `3.15` |
| `add1` | Increment by 1 | `{{ add1 5 }}` | `6` |
| `len` | Length (string/list/map) | `{{ len .Values.items }}` | count |
| `biggest` | Alias for max | `{{ biggest 1 5 }}` | `5` |

### Math in Templates

```yaml
# Calculate resource percentage
maxUnavailable: {{ div (mul .Values.replicaCount 25) 100 }}

# Conditional based on count
{{- if gt (len .Values.hosts) 0 }}
```

---

## Date Functions

| Function | Description | Example |
|----------|-------------|---------|
| `now` | Current time | `{{ now }}` |
| `date` | Format date | `{{ now \| date "2006-01-02" }}` |
| `dateInZone` | Format in timezone | `{{ dateInZone "2006-01-02" (now) "UTC" }}` |
| `dateModify` | Add duration to date | `{{ now \| dateModify "+2h" }}` |
| `duration` | Format seconds as duration | `{{ duration 3661 }}` → `1h1m1s` |
| `durationRound` | Round duration | `{{ durationRound "2h30m15s" }}` → `2h` |
| `htmlDate` | Date in HTML format | `{{ now \| htmlDate }}` → `2024-01-15` |
| `htmlDateInZone` | HTML date in timezone | `{{ htmlDateInZone (now) "UTC" }}` |
| `toDate` | Parse string to date | `{{ toDate "2006-01-02" "2024-01-15" }}` |
| `unixEpoch` | Date to Unix timestamp | `{{ now \| unixEpoch }}` |
| `ago` | Duration since date | `{{ ago .metadata.creationTimestamp }}` |

Go date format reference: `Mon Jan 2 15:04:05 MST 2006` (use this exact reference time).

---

## Default and Empty Functions

| Function | Description | Example |
|----------|-------------|---------|
| `default` | Return default if empty | `{{ .Values.port \| default 8080 }}` |
| `empty` | Test if value is empty | `{{ if empty .Values.name }}` |
| `coalesce` | Return first non-empty | `{{ coalesce .Values.name .Chart.Name "fallback" }}` |
| `all` | True if all args non-empty | `{{ if all .Values.a .Values.b }}` |
| `any` | True if any arg non-empty | `{{ if any .Values.a .Values.b }}` |
| `ternary` | Conditional value | `{{ .Values.enabled \| ternary "yes" "no" }}` |

**What counts as empty:** `false`, `0`, `nil`, `""`, empty list `[]`, empty map `{}`.

```yaml
# Coalesce is great for fallback chains
image: {{ coalesce .Values.image.tag .Chart.AppVersion "latest" }}

# Ternary for inline conditionals
replicas: {{ .Values.autoscaling.enabled | ternary 1 .Values.replicaCount }}
```

---

## Encoding Functions

| Function | Description | Example |
|----------|-------------|---------|
| `b64enc` | Base64 encode | `{{ "hello" \| b64enc }}` → `aGVsbG8=` |
| `b64dec` | Base64 decode | `{{ "aGVsbG8=" \| b64dec }}` → `hello` |
| `b32enc` | Base32 encode | `{{ "hello" \| b32enc }}` |
| `b32dec` | Base32 decode | `{{ "NBSWY3DP" \| b32dec }}` |

```yaml
# Common: encoding secrets
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "myapp.fullname" . }}
type: Opaque
data:
  password: {{ .Values.password | b64enc | quote }}
  # Or use stringData to avoid manual encoding:
stringData:
  password: {{ .Values.password | quote }}
```

---

## Crypto Functions

| Function | Description | Example |
|----------|-------------|---------|
| `sha1sum` | SHA-1 hash | `{{ "hello" \| sha1sum }}` |
| `sha256sum` | SHA-256 hash | `{{ "hello" \| sha256sum }}` |
| `adler32sum` | Adler-32 checksum | `{{ "hello" \| adler32sum }}` |
| `htpasswd` | Generate htpasswd entry | `{{ htpasswd "user" "pass" }}` |
| `derivePassword` | Password derivation | `{{ derivePassword 1 "long" "master" "user" "site" }}` |
| `genPrivateKey` | Generate PEM private key | `{{ genPrivateKey "rsa" }}` |
| `buildCustomCert` | Build custom certificate | `{{ buildCustomCert b64CertPEM b64KeyPEM }}` |
| `genCA` | Generate CA cert | `{{ $ca := genCA "my-ca" 365 }}` |
| `genSelfSignedCert` | Generate self-signed cert | `{{ $cert := genSelfSignedCert "my.host" nil nil 365 }}` |
| `genSignedCert` | Generate CA-signed cert | `{{ $cert := genSignedCert "my.host" nil nil 365 $ca }}` |
| `encryptAES` | AES encrypt | `{{ encryptAES "key123456789012" "text" }}` |
| `decryptAES` | AES decrypt | `{{ decryptAES "key123456789012" "encrypted" }}` |

### Checksum for Config Change Detection

```yaml
# Force pod restart when ConfigMap changes
spec:
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
        checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
```

### Self-Signed Certificate Generation

```yaml
{{- $cn := include "myapp.fullname" . -}}
{{- $ca := genCA "myapp-ca" 3650 -}}
{{- $cert := genSignedCert $cn nil (list (printf "%s.%s.svc" $cn .Release.Namespace)) 365 $ca -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ $cn }}-tls
type: kubernetes.io/tls
data:
  tls.crt: {{ $cert.Cert | b64enc }}
  tls.key: {{ $cert.Key | b64enc }}
  ca.crt: {{ $ca.Cert | b64enc }}
```

---

## List Functions

| Function | Description | Example |
|----------|-------------|---------|
| `list` | Create a list | `{{ list "a" "b" "c" }}` |
| `first` | First element | `{{ first (list "a" "b") }}` → `a` |
| `rest` | All except first | `{{ rest (list "a" "b" "c") }}` → `[b c]` |
| `last` | Last element | `{{ last (list "a" "b") }}` → `b` |
| `initial` | All except last | `{{ initial (list "a" "b" "c") }}` → `[a b]` |
| `append` | Append to list | `{{ append (list "a") "b" }}` → `[a b]` |
| `prepend` | Prepend to list | `{{ prepend (list "b") "a" }}` → `[a b]` |
| `concat` | Concatenate lists | `{{ concat (list "a") (list "b") }}` → `[a b]` |
| `reverse` | Reverse list | `{{ reverse (list 1 2 3) }}` → `[3 2 1]` |
| `uniq` | Remove duplicates | `{{ uniq (list "a" "a" "b") }}` → `[a b]` |
| `without` | Remove elements | `{{ without (list 1 2 3) 2 }}` → `[1 3]` |
| `has` | Check if list contains | `{{ has "a" (list "a" "b") }}` → `true` |
| `compact` | Remove empty strings | `{{ compact (list "a" "" "b") }}` → `[a b]` |
| `slice` | Slice a list | `{{ slice (list 1 2 3 4) 1 3 }}` → `[2 3]` |
| `until` | Generate int list 0..n-1 | `{{ until 5 }}` → `[0 1 2 3 4]` |
| `untilStep` | Int list with step | `{{ untilStep 0 10 2 }}` → `[0 2 4 6 8]` |
| `seq` | Sequence generator | `{{ seq 5 }}` → `1 2 3 4 5` |
| `sortAlpha` | Sort strings | `{{ sortAlpha (list "c" "a" "b") }}` → `[a b c]` |
| `chunk` | Split into chunks | `{{ chunk 2 (list 1 2 3 4) }}` → `[[1 2] [3 4]]` |

### List Patterns

```yaml
# Generate numbered replicas
{{- range $i := until (int .Values.replicaCount) }}
- name: worker-{{ $i }}
{{- end }}

# Check if value is in allowed list
{{- if has .Values.service.type (list "ClusterIP" "NodePort" "LoadBalancer") }}
type: {{ .Values.service.type }}
{{- else }}
{{ fail (printf "Invalid service type: %s" .Values.service.type) }}
{{- end }}

# Merge environment variable lists
env:
  {{- $env := concat .Values.env (.Values.extraEnv | default list) }}
  {{- toYaml $env | nindent 2 }}
```

---

## Dictionary Functions

| Function | Description | Example |
|----------|-------------|---------|
| `dict` | Create dictionary | `{{ dict "key" "value" "k2" "v2" }}` |
| `set` | Set key in dict (mutates) | `{{ set $d "key" "value" }}` |
| `unset` | Remove key (mutates) | `{{ unset $d "key" }}` |
| `hasKey` | Check if key exists | `{{ hasKey $d "key" }}` → `true/false` |
| `pluck` | Get key from list of dicts | `{{ pluck "name" $d1 $d2 }}` → list |
| `dig` | Deep-get nested key | `{{ dig "a" "b" "c" "default" $d }}` |
| `merge` | Merge dicts (first wins) | `{{ merge $dst $src1 $src2 }}` |
| `mergeOverwrite` | Merge dicts (last wins) | `{{ mergeOverwrite $dst $src }}` |
| `keys` | Get all keys | `{{ keys $d }}` → list |
| `values` | Get all values | `{{ values $d }}` → list |
| `pick` | Keep only specified keys | `{{ pick $d "a" "b" }}` |
| `omit` | Remove specified keys | `{{ omit $d "a" "b" }}` |
| `deepCopy` | Deep copy dict | `{{ deepCopy $d }}` |
| `get` | Get key value | `{{ get $d "key" }}` |

### Dictionary Patterns

```yaml
# Build annotations dict dynamically
{{- $annotations := dict }}
{{- if .Values.ingress.certManager }}
  {{- $_ := set $annotations "cert-manager.io/cluster-issuer" .Values.ingress.certManager }}
{{- end }}
{{- if .Values.ingress.class }}
  {{- $_ := set $annotations "kubernetes.io/ingress.class" .Values.ingress.class }}
{{- end }}
{{- with $annotations }}
annotations:
  {{- toYaml . | nindent 4 }}
{{- end }}

# Safe nested access with dig
port: {{ dig "service" "port" 8080 .Values }}
# Returns 8080 if .Values.service.port doesn't exist

# Merge default labels with user-provided
{{- $labels := merge (dict) .Values.extraLabels (include "myapp.labels" . | fromYaml) }}
```

---

## Type Conversion Functions

| Function | Description | Example |
|----------|-------------|---------|
| `atoi` | String to int | `{{ "42" \| atoi }}` → `42` |
| `int` | Convert to int | `{{ int "42" }}` |
| `int64` | Convert to int64 | `{{ int64 "42" }}` |
| `float64` | Convert to float64 | `{{ float64 "3.14" }}` |
| `toString` | Convert to string | `{{ 42 \| toString }}` |
| `toStrings` | Convert list to strings | `{{ list 1 2 3 \| toStrings }}` |
| `toDecimal` | Octal string to int | `{{ "0777" \| toDecimal }}` → `511` |
| `kindOf` | Get Go type | `{{ kindOf "hello" }}` → `string` |
| `kindIs` | Check Go type | `{{ kindIs "string" "hello" }}` → `true` |
| `typeOf` | Get precise Go type | `{{ typeOf 42 }}` → `int` |
| `typeIs` | Check precise type | `{{ typeIs "int" 42 }}` → `true` |
| `deepEqual` | Deep equality check | `{{ deepEqual $a $b }}` |

```yaml
# Common: ensure port is integer
containerPort: {{ .Values.port | int }}

# Ensure boolean
readOnly: {{ .Values.readOnly | toString | lower | eq "true" }}
```

---

## Flow Control

### if/else

```yaml
{{- if .Values.ingress.enabled }}
# render ingress
{{- else if .Values.route.enabled }}
# render OpenShift route
{{- else }}
# render nodeport service
{{- end }}
```

### with — Change Scope

```yaml
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}

# Access root inside with:
{{- with .Values.config }}
name: {{ $.Release.Name }}    {{/* $ = root context */}}
data: {{ . | toYaml }}
{{- end }}
```

### range — Iteration

```yaml
# Over a list
{{- range .Values.ports }}
- port: {{ .port }}
  name: {{ .name }}
{{- end }}

# Over a map
{{- range $key, $value := .Values.env }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}

# With index
{{- range $index, $host := .Values.hosts }}
  {{- if $index }},{{ end }}{{ $host }}
{{- end }}

# Over a generated range
{{- range $i := until 3 }}
- name: worker-{{ $i }}
{{- end }}
```

### Logical Operators

```yaml
{{ if and .Values.a .Values.b }}          {{/* AND */}}
{{ if or .Values.a .Values.b }}           {{/* OR */}}
{{ if not .Values.a }}                     {{/* NOT */}}
{{ if eq .Values.type "production" }}      {{/* Equal */}}
{{ if ne .Values.env "dev" }}              {{/* Not equal */}}
{{ if lt .Values.count 5 }}               {{/* Less than */}}
{{ if le .Values.count 5 }}               {{/* Less or equal */}}
{{ if gt .Values.count 0 }}               {{/* Greater than */}}
{{ if ge .Values.count 1 }}               {{/* Greater or equal */}}
```

### fail — Intentional Error

```yaml
{{- if not (has .Values.type (list "ClusterIP" "NodePort" "LoadBalancer")) }}
  {{ fail (printf "Invalid service type '%s'. Must be one of: ClusterIP, NodePort, LoadBalancer" .Values.type) }}
{{- end }}
```

---

## Named Templates

### Define and Include

```yaml
{{/* _helpers.tpl */}}
{{- define "myapp.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/* Usage — always use include, not template */}}
name: {{ include "myapp.fullname" . }}
labels:
  {{- include "myapp.labels" . | nindent 4 }}
```

### Passing Custom Context

```yaml
{{- define "myapp.env" -}}
{{- range $key, $val := .env }}
- name: {{ $key }}
  value: {{ $val | quote }}
{{- end }}
{{- end }}

{{/* Pass a custom dict as context */}}
env:
  {{- include "myapp.env" (dict "env" .Values.environment) | nindent 2 }}
```

### Template in Template (Nested)

```yaml
{{- define "myapp.annotations" -}}
{{- with .Values.annotations }}
{{- tpl (toYaml .) $ }}
{{- end }}
{{- end }}
```

This allows values.yaml to contain template expressions:

```yaml
annotations:
  app-version: "{{ .Chart.AppVersion }}"
```

---

## Path and File Functions

| Function | Description | Example |
|----------|-------------|---------|
| `base` | Filename from path | `{{ base "/a/b/c.txt" }}` → `c.txt` |
| `dir` | Directory from path | `{{ dir "/a/b/c.txt" }}` → `/a/b` |
| `ext` | File extension | `{{ ext "c.txt" }}` → `.txt` |
| `clean` | Clean path | `{{ clean "/a/../b" }}` → `/b` |
| `isAbs` | Is absolute path | `{{ isAbs "/a/b" }}` → `true` |

---

## Regex Functions

| Function | Description | Example |
|----------|-------------|---------|
| `regexMatch` | Test regex match | `{{ regexMatch "^[a-z]+$" "hello" }}` → `true` |
| `regexFind` | Find first match | `{{ regexFind "[0-9]+" "abc123" }}` → `123` |
| `regexFindAll` | Find all matches | `{{ regexFindAll "[0-9]+" "a1b2" -1 }}` → `[1 2]` |
| `regexReplaceAll` | Replace all matches | `{{ regexReplaceAll "[^a-z]" "a1b2" "" }}` → `ab` |
| `regexReplaceAllLiteral` | Replace (no expand) | `{{ regexReplaceAllLiteral "\\d" "a1b2" "x" }}` → `axbx` |
| `regexSplit` | Split by regex | `{{ regexSplit "\\s+" "a b  c" -1 }}` → `[a b c]` |
| `mustRegexMatch` | Match or fail | `{{ mustRegexMatch "^v\\d" .Values.tag }}` |

```yaml
# Validate image tag format
{{- if not (regexMatch "^v[0-9]+\\.[0-9]+\\.[0-9]+$" .Values.image.tag) }}
  {{- if ne .Values.image.tag "" }}
    {{- fail (printf "image.tag '%s' must match semver format v0.0.0" .Values.image.tag) }}
  {{- end }}
{{- end }}
```

---

## Semantic Version Functions

| Function | Description | Example |
|----------|-------------|---------|
| `semver` | Parse semver string | `{{ $v := semver "1.2.3-beta.1+build" }}` |
| `semverCompare` | Compare semver constraint | `{{ semverCompare ">=1.20-0" .Capabilities.KubeVersion.GitVersion }}` |

```yaml
# API version selection based on cluster version
{{- if semverCompare ">=1.19-0" .Capabilities.KubeVersion.GitVersion }}
apiVersion: networking.k8s.io/v1
{{- else }}
apiVersion: networking.k8s.io/v1beta1
{{- end }}

# Parsed semver object fields: .Major, .Minor, .Patch, .Prerelease, .Original
{{ $v := semver .Chart.AppVersion }}
major: {{ $v.Major }}
```

---

## UUID and Random Functions

| Function | Description | Example |
|----------|-------------|---------|
| `uuidv4` | Generate UUID v4 | `{{ uuidv4 }}` |
| `randAlphaNum` | Random alphanumeric | `{{ randAlphaNum 16 }}` |
| `randAlpha` | Random alpha chars | `{{ randAlpha 10 }}` |
| `randNumeric` | Random digits | `{{ randNumeric 6 }}` |
| `randAscii` | Random ASCII chars | `{{ randAscii 20 }}` |

**Warning:** Random functions generate new values on every `helm template`/`helm upgrade`. For passwords, use `lookup` to preserve existing values:

```yaml
{{- $secret := lookup "v1" "Secret" .Release.Namespace (include "myapp.fullname" .) }}
{{- $password := "" }}
{{- if $secret }}
  {{- $password = index $secret.data "password" | b64dec }}
{{- else }}
  {{- $password = randAlphaNum 32 }}
{{- end }}
data:
  password: {{ $password | b64enc | quote }}
```

---

## OS and Environment Functions

| Function | Description | Example |
|----------|-------------|---------|
| `env` | Read environment variable | `{{ env "HOME" }}` |
| `expandenv` | Expand `$VAR` in string | `{{ expandenv "$HOME/app" }}` |

**Security note:** `env` and `expandenv` are disabled by default in Helm templates for security. They work only in Helm plugins and custom tools.

---

## Common Helm Idioms

### Kubernetes Name Compliance (DNS-1123)

```yaml
{{- define "myapp.name" -}}
{{- .Values.nameOverride | default .Chart.Name | trunc 63 | trimSuffix "-" | lower | replace "_" "-" }}
{{- end }}
```

### Merge Annotations from Multiple Sources

```yaml
metadata:
  annotations:
    {{- $annotations := merge (dict) (.Values.commonAnnotations | default dict) (.Values.podAnnotations | default dict) }}
    {{- with $annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
```

### Image Pull Policy Logic

```yaml
imagePullPolicy: {{ .Values.image.pullPolicy | default (ternary "Always" "IfNotPresent" (eq .Values.image.tag "latest")) }}
```

### Config Checksum Annotation

```yaml
annotations:
  checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

### Safe toYaml with Empty Check

```yaml
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
```

### Render Values as Template Strings

```yaml
# values.yaml
customAnnotation: "deployed-by-{{ .Release.Name }}"

# template
annotations:
  custom: {{ tpl .Values.customAnnotation . | quote }}
```
