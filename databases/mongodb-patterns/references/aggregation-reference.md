# MongoDB Aggregation Pipeline Reference

## Table of Contents

- [Pipeline Stages](#pipeline-stages)
  - [$match](#match)
  - [$project and $addFields](#project-and-addfields)
  - [$group](#group)
  - [$sort](#sort)
  - [$limit and $skip](#limit-and-skip)
  - [$lookup](#lookup)
  - [$unwind](#unwind)
  - [$facet](#facet)
  - [$bucket and $bucketAuto](#bucket-and-bucketauto)
  - [$merge and $out](#merge-and-out)
  - [$unionWith](#unionwith)
  - [$graphLookup](#graphlookup)
  - [$setWindowFields](#setwindowfields)
  - [$densify](#densify)
  - [$fill](#fill)
  - [$search and $searchMeta](#search-and-searchmeta)
  - [$sample](#sample)
  - [$replaceRoot and $replaceWith](#replaceroot-and-replacewith)
  - [$redact](#redact)
  - [$count](#count)
  - [$set and $unset](#set-and-unset)
  - [$changeStream](#changestream)
  - [$documents](#documents)
- [Expression Operators](#expression-operators)
  - [Comparison](#comparison)
  - [Arithmetic](#arithmetic)
  - [String](#string)
  - [Array](#array)
  - [Date](#date)
  - [Conditional](#conditional)
  - [Type and Conversion](#type-and-conversion)
  - [Object](#object)
- [Accumulator Operators](#accumulator-operators)
  - [Basic Accumulators](#basic-accumulators)
  - [Array Accumulators](#array-accumulators)
  - [Statistical Accumulators](#statistical-accumulators)
- [Window Functions](#window-functions)
  - [Window Definitions](#window-definitions)
  - [Window Operators](#window-operators)
- [Atlas Search Integration](#atlas-search-integration)
  - [Search Operators](#search-operators)
  - [Scoring and Highlighting](#scoring-and-highlighting)
  - [Facet Search](#facet-search)

---

## Pipeline Stages

### $match

Filters documents. Place first for index usage. Multiple adjacent $match stages auto-merge.

```javascript
// Simple filter
{ $match: { status: "active", age: { $gte: 21 } } }

// With $expr for field comparisons
{ $match: { $expr: { $gt: ["$revenue", "$costs"] } } }

// Regex (prefix-anchored for index use)
{ $match: { name: /^Joh/i } }

// Exists check
{ $match: { email: { $exists: true, $ne: null } } }

// Compound conditions
{ $match: {
  $or: [
    { status: "active", tier: "premium" },
    { createdAt: { $gte: ISODate("2024-01-01") } }
  ]
}}
```

### $project and $addFields

`$project` includes/excludes/computes fields. `$addFields` only adds (keeps all existing).

```javascript
// Include specific fields
{ $project: { name: 1, email: 1, _id: 0 } }

// Computed fields
{ $project: {
  fullName: { $concat: ["$firstName", " ", "$lastName"] },
  totalPrice: { $multiply: ["$price", "$quantity"] },
  year: { $year: "$createdAt" },
  hasDiscount: { $gt: ["$discount", 0] }
}}

// $addFields (alias: $set) — adds fields without removing existing
{ $addFields: {
  totalWithTax: { $multiply: ["$total", 1.08] },
  isExpensive: { $gte: ["$price", 100] }
}}

// Nested field projection
{ $project: {
  "address.city": 1,
  "address.state": 1,
  "items.name": 1
}}

// Exclude specific fields
{ $project: { password: 0, ssn: 0, __v: 0 } }
```

### $group

Groups documents by expression. Blocking stage — holds all groups in memory.

```javascript
// Basic grouping with accumulators
{ $group: {
  _id: "$category",
  totalRevenue: { $sum: "$price" },
  avgPrice: { $avg: "$price" },
  count: { $sum: 1 },
  maxPrice: { $max: "$price" },
  minPrice: { $min: "$price" }
}}

// Group by multiple fields
{ $group: {
  _id: { year: { $year: "$date" }, month: { $month: "$date" }, category: "$category" },
  sales: { $sum: "$amount" }
}}

// Group all documents (single group)
{ $group: {
  _id: null,
  totalDocs: { $sum: 1 },
  avgScore: { $avg: "$score" }
}}

// Collect into arrays
{ $group: {
  _id: "$department",
  employees: { $push: "$name" },
  topSalary: { $max: "$salary" },
  uniqueTitles: { $addToSet: "$title" }
}}

// $group + $project for clean output
[
  { $group: { _id: "$status", count: { $sum: 1 } } },
  { $project: { _id: 0, status: "$_id", count: 1 } }
]
```

### $sort

Sorts documents. Blocking stage unless preceded by index-aligned $match.

```javascript
// Sort by field (1=asc, -1=desc)
{ $sort: { createdAt: -1 } }

// Multi-field sort
{ $sort: { category: 1, price: -1 } }

// Text score sort (after $text or $search)
{ $sort: { score: { $meta: "textScore" } } }

// PERFORMANCE: $sort + $limit adjacent = top-k optimization (memory-efficient)
// $sort followed by $limit uses in-memory top-k sort, not full sort
[
  { $sort: { score: -1 } },
  { $limit: 10 }
]

// 100MB memory limit for $sort. If exceeded:
// Option 1: { allowDiskUse: true }  — uses temp files
// Option 2: Index on sort fields to avoid in-memory sort
```

### $limit and $skip

```javascript
// Limit results
{ $limit: 10 }

// Skip (for pagination — avoid for large offsets)
{ $skip: 20 }

// Pagination pattern (prefer range-based over skip-based)
// Skip-based (slow for large offsets):
[{ $sort: { createdAt: -1 } }, { $skip: 10000 }, { $limit: 20 }]

// Range-based (fast, consistent):
{ $match: { createdAt: { $lt: lastSeenDate } } },
{ $sort: { createdAt: -1 } },
{ $limit: 20 }
```

### $lookup

Left outer join. Always index the foreign field.

```javascript
// Basic equality join
{ $lookup: {
  from: "customers",
  localField: "customerId",
  foreignField: "_id",
  as: "customer"    // always an array (even if 0 or 1 match)
}}

// Pipeline form (most flexible — parameterized, filtered joins)
{ $lookup: {
  from: "orders",
  let: { custId: "$_id", minDate: ISODate("2024-01-01") },
  pipeline: [
    { $match: { $expr: {
      $and: [
        { $eq: ["$customerId", "$$custId"] },
        { $gte: ["$createdAt", "$$minDate"] }
      ]
    }}},
    { $project: { total: 1, status: 1 } },
    { $sort: { createdAt: -1 } },
    { $limit: 5 }
  ],
  as: "recentOrders"
}}

// Uncorrelated subquery (no let — same subpipeline for all docs)
{ $lookup: {
  from: "settings",
  pipeline: [
    { $match: { key: "taxRate" } },
    { $project: { _id: 0, value: 1 } }
  ],
  as: "taxConfig"
}}

// Self-join
{ $lookup: {
  from: "employees",    // same collection
  localField: "managerId",
  foreignField: "_id",
  as: "manager"
}}

// Common pattern: $lookup + $unwind to "join"
[
  { $lookup: { from: "categories", localField: "catId", foreignField: "_id", as: "category" } },
  { $unwind: { path: "$category", preserveNullAndEmptyArrays: true } }
  // Result: category is now a single object (or null), not an array
]
```

### $unwind

Deconstructs an array field into one document per element.

```javascript
// Basic unwind
{ $unwind: "$tags" }
// Input:  { _id: 1, tags: ["a", "b", "c"] }
// Output: { _id: 1, tags: "a" }, { _id: 1, tags: "b" }, { _id: 1, tags: "c" }

// Preserve null/missing/empty arrays
{ $unwind: { path: "$tags", preserveNullAndEmptyArrays: true } }
// Docs without tags or with empty array are kept (tags = null)

// Include array index
{ $unwind: { path: "$items", includeArrayIndex: "itemIndex" } }

// WARNING: $unwind on large arrays multiplies document count dramatically
// Prefer $filter, $reduce, or $map when possible
```

### $facet

Run multiple sub-pipelines on the same input. Each sub-pipeline is independent.

```javascript
{ $facet: {
  // Facet 1: Price ranges
  priceRanges: [
    { $bucket: { groupBy: "$price", boundaries: [0, 25, 50, 100, Infinity], default: "Other",
      output: { count: { $sum: 1 } } } }
  ],

  // Facet 2: Top categories
  topCategories: [
    { $group: { _id: "$category", count: { $sum: 1 } } },
    { $sort: { count: -1 } },
    { $limit: 5 }
  ],

  // Facet 3: Total count
  totalCount: [
    { $count: "count" }
  ]
}}

// LIMITATIONS:
// - Each sub-pipeline receives ALL input documents (no index use inside $facet)
// - Cannot include $out, $merge, $facet, or $search in sub-pipelines
// - Entire $facet output must fit in one 16MB document
// TIP: Place $match BEFORE $facet to reduce input set
```

### $bucket and $bucketAuto

```javascript
// $bucket: manual boundaries
{ $bucket: {
  groupBy: "$price",
  boundaries: [0, 25, 50, 100, 200, 500],  // creates 5 buckets
  default: "500+",
  output: {
    count: { $sum: 1 },
    avgPrice: { $avg: "$price" },
    items: { $push: "$name" }
  }
}}
// Output: { _id: 0, count: 15, ... }, { _id: 25, count: 42, ... }, ...

// $bucketAuto: automatically determines boundaries
{ $bucketAuto: {
  groupBy: "$score",
  buckets: 5,            // number of buckets
  granularity: "R5",     // optional: R5, R10, R20, R40, R80, 1-2-5, E6-E192, POWERSOF2
  output: {
    count: { $sum: 1 },
    avgScore: { $avg: "$score" }
  }
}}
// Output: { _id: { min: 0, max: 20 }, count: 150, ... }, ...
```

### $merge and $out

```javascript
// $out: replace entire collection
{ $out: "report_summary" }
// Or to different database:
{ $out: { db: "reporting", coll: "summary" } }
// WARNING: drops and recreates target collection (loses indexes)

// $merge: upsert into existing collection (preferred)
{ $merge: {
  into: "monthly_stats",
  on: ["year", "month", "category"],   // match fields (must have unique index)
  whenMatched: "replace",              // replace | keepExisting | merge | fail | pipeline
  whenNotMatched: "insert"             // insert | discard | fail
}}

// $merge with pipeline update (most flexible)
{ $merge: {
  into: "running_totals",
  on: "_id",
  whenMatched: [
    { $addFields: {
      total: { $add: ["$total", "$$new.incrementalTotal"] },
      lastUpdated: "$$NOW"
    }}
  ],
  whenNotMatched: "insert"
}}
```

### $unionWith

Combines results from multiple collections (like SQL UNION ALL).

```javascript
// Union orders from archive collection
db.orders.aggregate([
  { $match: { status: "pending" } },
  { $unionWith: {
    coll: "orders_archive",
    pipeline: [{ $match: { status: "pending" } }]
  }},
  { $sort: { createdAt: -1 } }
]);

// Union from multiple collections
[
  { $unionWith: { coll: "collection_b", pipeline: [] } },
  { $unionWith: { coll: "collection_c", pipeline: [] } },
  { $group: { _id: "$type", count: { $sum: 1 } } }
]
```

### $graphLookup

Recursive lookup for tree/graph traversal.

```javascript
{ $graphLookup: {
  from: "employees",
  startWith: "$managerId",         // starting value(s)
  connectFromField: "managerId",   // field to recurse on
  connectToField: "_id",           // field to match against
  as: "reportingChain",
  maxDepth: 10,                    // limit recursion depth
  depthField: "level",             // adds depth info to results
  restrictSearchWithMatch: { active: true }  // filter during traversal
}}

// BOM (Bill of Materials) explosion
db.parts.aggregate([
  { $match: { _id: "widget-A" } },
  { $graphLookup: {
    from: "parts",
    startWith: "$components.partId",
    connectFromField: "components.partId",
    connectToField: "_id",
    as: "allSubParts",
    maxDepth: 5
  }}
]);
```

### $setWindowFields

Window functions for running calculations over sorted partitions (5.0+).

```javascript
{ $setWindowFields: {
  partitionBy: "$department",             // group rows
  sortBy: { hireDate: 1 },               // order within partition
  output: {
    // Running total
    cumulativeSalary: {
      $sum: "$salary",
      window: { documents: ["unbounded", "current"] }
    },
    // Rank
    salaryRank: {
      $rank: {}
    },
    // Moving average
    movingAvgSalary: {
      $avg: "$salary",
      window: { documents: [-2, 0] }  // 3-doc trailing window
    },
    // Lag/Lead
    previousEmployee: {
      $shift: { output: "$name", by: -1, default: "N/A" }
    }
  }
}}

// Time-based window
{ $setWindowFields: {
  partitionBy: "$sensorId",
  sortBy: { timestamp: 1 },
  output: {
    hourlyAvg: {
      $avg: "$value",
      window: { range: [-1, 0], unit: "hour" }  // trailing 1 hour
    }
  }
}}
```

### $densify

Fill gaps in time series or numeric sequences (5.1+).

```javascript
// Fill missing hourly data points
{ $densify: {
  field: "timestamp",
  partitionByFields: ["sensorId"],
  range: {
    step: 1,
    unit: "hour",
    bounds: [ISODate("2024-01-01"), ISODate("2024-01-02")]
  }
}}

// Numeric densify
{ $densify: {
  field: "score",
  range: { step: 10, bounds: [0, 100] }
}}
```

### $fill

Fill null/missing values (5.3+).

```javascript
// Forward fill (LOCF - Last Observation Carried Forward)
{ $fill: {
  sortBy: { timestamp: 1 },
  partitionBy: "$sensorId",
  output: {
    temperature: { method: "locf" },  // carry last known value
    humidity: { method: "linear" }     // linear interpolation
  }
}}

// Fill with constant
{ $fill: {
  output: {
    status: { value: "unknown" },
    score: { value: 0 }
  }
}}
```

### $search and $searchMeta

Atlas Search stages (Atlas only). Must be first stage.

```javascript
// $search: returns matching documents
{ $search: {
  index: "default",
  text: { query: "mongodb aggregation", path: ["title", "body"] }
}}

// $searchMeta: returns metadata only (counts, facets)
{ $searchMeta: {
  index: "default",
  facet: {
    operator: { text: { query: "database", path: "title" } },
    facets: {
      categoryFacet: { type: "string", path: "category", numBuckets: 10 },
      dateFacet: { type: "date", path: "publishDate",
        boundaries: [ISODate("2023-01-01"), ISODate("2024-01-01"), ISODate("2025-01-01")] }
    }
  }
}}
```

### $sample

Random document selection.

```javascript
// Get 5 random documents
{ $sample: { size: 5 } }
// If size < 5% of collection and collection > 100 docs, uses random cursor (fast)
// Otherwise, sorts entire collection randomly (slow)
```

### $replaceRoot and $replaceWith

Replace the document with a subdocument or expression.

```javascript
// Promote nested field to root
{ $replaceRoot: { newRoot: "$address" } }
// Input:  { name: "Alice", address: { city: "NYC", zip: "10001" } }
// Output: { city: "NYC", zip: "10001" }

// $replaceWith (alias for $replaceRoot.newRoot)
{ $replaceWith: { $mergeObjects: [{ defaults: true }, "$overrides"] } }
```

### $redact

Document-level access control. Prunes document tree based on conditions.

```javascript
{ $redact: {
  $cond: {
    if: { $in: ["$accessLevel", ["public", userRole]] },
    then: "$$DESCEND",    // include this level and check children
    else: "$$PRUNE"       // exclude this level and all children
  }
}}
// $$KEEP    — include doc and all children (no further checks)
// $$DESCEND — include this level, check children
// $$PRUNE   — exclude this level and all below
```

### $count

Counts documents at this pipeline stage.

```javascript
{ $count: "totalResults" }
// Output: { totalResults: 42 }
// Equivalent to: { $group: { _id: null, totalResults: { $sum: 1 } } }
```

### $set and $unset

Aliases for $addFields and $project (exclusion only).

```javascript
// $set = $addFields
{ $set: { fullName: { $concat: ["$first", " ", "$last"] } } }

// $unset = $project with exclusion
{ $unset: ["password", "ssn", "internalNotes"] }
// Equivalent to: { $project: { password: 0, ssn: 0, internalNotes: 0 } }
```

### $changeStream

Use change stream as aggregation stage (6.0+).

```javascript
// Programmatic change stream via aggregation
db.orders.aggregate([
  { $changeStream: {
    fullDocument: "updateLookup",
    fullDocumentBeforeChange: "whenAvailable"
  }},
  { $match: { operationType: "update" } }
]);
```

### $documents

Generate documents from expressions (no collection needed, 5.1+).

```javascript
// Use with $lookup for inline test data
{ $documents: [
  { x: 1, y: "a" },
  { x: 2, y: "b" },
  { x: 3, y: "c" }
]}
```

---

## Expression Operators

### Comparison

```javascript
$eq:  { $eq: ["$a", "$b"] }       // a == b
$ne:  { $ne: ["$a", "$b"] }       // a != b
$gt:  { $gt: ["$a", 100] }        // a > 100
$gte: { $gte: ["$a", 100] }       // a >= 100
$lt:  { $lt: ["$a", 100] }        // a < 100
$lte: { $lte: ["$a", 100] }       // a <= 100
$cmp: { $cmp: ["$a", "$b"] }      // returns -1, 0, or 1

// In array check
$in: { $in: ["$status", ["active", "pending"]] }
```

### Arithmetic

```javascript
$add:      { $add: ["$price", "$tax"] }           // also adds dates + milliseconds
$subtract: { $subtract: ["$total", "$discount"] }
$multiply: { $multiply: ["$price", "$qty"] }
$divide:   { $divide: ["$total", "$count"] }
$mod:      { $mod: ["$hours", 24] }
$abs:      { $abs: "$difference" }
$ceil:     { $ceil: "$price" }
$floor:    { $floor: "$price" }
$round:    { $round: ["$price", 2] }               // round to 2 decimal places
$trunc:    { $trunc: ["$price", 2] }               // truncate to 2 decimal places
$pow:      { $pow: ["$base", "$exponent"] }
$sqrt:     { $sqrt: "$variance" }
$log:      { $log: ["$value", 10] }
$log10:    { $log10: "$value" }
$ln:       { $ln: "$value" }
$exp:      { $exp: "$power" }                       // e^power
```

### String

```javascript
$concat:       { $concat: ["$first", " ", "$last"] }
$substr:       { $substr: ["$str", 0, 5] }           // deprecated, use $substrBytes
$substrBytes:  { $substrBytes: ["$str", 0, 5] }
$substrCP:     { $substrCP: ["$str", 0, 5] }          // code point based
$toLower:      { $toLower: "$name" }
$toUpper:      { $toUpper: "$code" }
$trim:         { $trim: { input: "$name" } }
$ltrim:        { $ltrim: { input: "$name", chars: " \t" } }
$rtrim:        { $rtrim: { input: "$name" } }
$split:        { $split: ["$fullName", " "] }          // returns array
$strLenBytes:  { $strLenBytes: "$name" }
$strLenCP:     { $strLenCP: "$name" }
$indexOfBytes:  { $indexOfBytes: ["$str", "search"] }  // -1 if not found
$regexMatch:   { $regexMatch: { input: "$email", regex: /^[a-z]+@/ } }
$regexFind:    { $regexFind: { input: "$str", regex: /pattern/ } }
$regexFindAll: { $regexFindAll: { input: "$str", regex: /\d+/g } }
$replaceOne:   { $replaceOne: { input: "$str", find: "old", replacement: "new" } }
$replaceAll:   { $replaceAll: { input: "$str", find: "old", replacement: "new" } }
```

### Array

```javascript
$arrayElemAt:  { $arrayElemAt: ["$items", 0] }         // first element
$first:        { $first: "$items" }                     // alias for arrayElemAt 0
$last:         { $last: "$items" }                      // last element
$size:         { $size: "$tags" }                       // array length
$slice:        { $slice: ["$items", 0, 5] }             // subarray
$concatArrays: { $concatArrays: ["$arr1", "$arr2"] }
$in:           { $in: ["value", "$arrayField"] }        // element in array
$isArray:      { $isArray: "$field" }
$reverseArray: { $reverseArray: "$items" }
$sortArray:    { $sortArray: { input: "$scores", sortBy: { score: -1 } } }

// $filter: keep matching elements
{ $filter: {
  input: "$items",
  as: "item",
  cond: { $gte: ["$$item.price", 100] }
}}

// $map: transform each element
{ $map: {
  input: "$items",
  as: "item",
  in: { name: "$$item.name", total: { $multiply: ["$$item.price", "$$item.qty"] } }
}}

// $reduce: fold array to single value
{ $reduce: {
  input: "$items",
  initialValue: 0,
  in: { $add: ["$$value", "$$this.price"] }
}}

// $zip: merge parallel arrays
{ $zip: { inputs: ["$names", "$scores"], useLongestLength: true, defaults: [null, 0] } }

// $setUnion, $setIntersection, $setDifference: set operations
{ $setUnion: ["$tags1", "$tags2"] }
{ $setIntersection: ["$tags1", "$tags2"] }
{ $setDifference: ["$tags1", "$tags2"] }  // in tags1 but not tags2
```

### Date

```javascript
$dateFromParts: { $dateFromParts: { year: 2024, month: 11, day: 15 } }
$dateToParts:   { $dateToParts: { date: "$createdAt" } }  // { year, month, day, hour, ... }
$dateFromString: { $dateFromString: { dateString: "2024-11-15", format: "%Y-%m-%d" } }
$dateToString:  { $dateToString: { format: "%Y-%m-%d", date: "$createdAt" } }
$dateTrunc:     { $dateTrunc: { date: "$ts", unit: "hour" } }  // truncate to hour
$dateAdd:       { $dateAdd: { startDate: "$createdAt", unit: "day", amount: 30 } }
$dateSubtract:  { $dateSubtract: { startDate: "$createdAt", unit: "hour", amount: 2 } }
$dateDiff:      { $dateDiff: { startDate: "$start", endDate: "$end", unit: "day" } }

// Extract components
$year:        { $year: "$date" }
$month:       { $month: "$date" }
$dayOfMonth:  { $dayOfMonth: "$date" }
$dayOfWeek:   { $dayOfWeek: "$date" }      // 1=Sunday, 7=Saturday
$dayOfYear:   { $dayOfYear: "$date" }
$hour:        { $hour: "$date" }
$minute:      { $minute: "$date" }
$second:      { $second: "$date" }
$millisecond: { $millisecond: "$date" }
$isoWeek:     { $isoWeek: "$date" }
$isoWeekYear: { $isoWeekYear: "$date" }
```

### Conditional

```javascript
// If-then-else
$cond: { $cond: { if: { $gte: ["$score", 90] }, then: "A", else: "B" } }
// Short form:
$cond: { $cond: [{ $gte: ["$score", 90] }, "A", "B"] }

// Null coalescing
$ifNull: { $ifNull: ["$nickname", "$name", "Anonymous"] }  // first non-null

// Multi-branch switch
$switch: { $switch: {
  branches: [
    { case: { $gte: ["$score", 90] }, then: "A" },
    { case: { $gte: ["$score", 80] }, then: "B" },
    { case: { $gte: ["$score", 70] }, then: "C" }
  ],
  default: "F"
}}
```

### Type and Conversion

```javascript
$type:     { $type: "$field" }                    // returns BSON type name
$convert:  { $convert: { input: "$val", to: "int", onError: 0, onNull: 0 } }
$toInt:    { $toInt: "$strNum" }
$toLong:   { $toLong: "$strNum" }
$toDouble: { $toDouble: "$strNum" }
$toDecimal: { $toDecimal: "$strNum" }
$toString: { $toString: "$numVal" }
$toDate:   { $toDate: "$timestamp" }
$toObjectId: { $toObjectId: "$strId" }
$toBool:   { $toBool: "$val" }
$isNumber: { $isNumber: "$field" }
```

### Object

```javascript
$mergeObjects: { $mergeObjects: ["$defaults", "$overrides"] }
$objectToArray: { $objectToArray: "$metadata" }
// { a: 1, b: 2 } -> [{ k: "a", v: 1 }, { k: "b", v: 2 }]

$arrayToObject: { $arrayToObject: "$kvPairs" }
// [{ k: "a", v: 1 }] -> { a: 1 }

// Dynamic field access (6.1+)
$getField: { $getField: { field: "my.dotted.field", input: "$$ROOT" } }
$setField: { $setField: { field: "status", input: "$$ROOT", value: "active" } }
```

---

## Accumulator Operators

Used in `$group`, `$bucket`, `$setWindowFields`.

### Basic Accumulators

```javascript
$sum:   { $sum: "$amount" }        // sum values; { $sum: 1 } counts docs
$avg:   { $avg: "$score" }         // average
$min:   { $min: "$price" }         // minimum
$max:   { $max: "$price" }         // maximum
$count: { $count: {} }             // count docs (5.0+, in $group)
$first: { $first: "$name" }       // first value (order-dependent, use with $sort before $group)
$last:  { $last: "$name" }        // last value

// In $group with $sort preceding:
[
  { $sort: { createdAt: 1 } },
  { $group: { _id: "$userId", firstOrder: { $first: "$orderId" }, lastOrder: { $last: "$orderId" } } }
]
```

### Array Accumulators

```javascript
$push:     { $push: "$item" }          // collect all values into array
$addToSet: { $addToSet: "$tag" }       // collect unique values

// $push with expression
$push: { $push: { product: "$name", qty: "$quantity" } }

// First/last N (5.2+)
$firstN: { $firstN: { input: "$name", n: 3 } }
$lastN:  { $lastN: { input: "$name", n: 3 } }
$maxN:   { $maxN: { input: "$score", n: 5 } }    // top 5 scores
$minN:   { $minN: { input: "$score", n: 5 } }    // bottom 5 scores

// Top/bottom (5.2+)
$top: { $top: { sortBy: { score: -1 }, output: ["$name", "$score"] } }
$topN: { $topN: { sortBy: { score: -1 }, output: "$name", n: 3 } }
$bottom: { $bottom: { sortBy: { score: -1 }, output: "$name" } }
$bottomN: { $bottomN: { sortBy: { score: -1 }, output: "$name", n: 3 } }
```

### Statistical Accumulators

```javascript
$stdDevPop:  { $stdDevPop: "$score" }    // population standard deviation
$stdDevSamp: { $stdDevSamp: "$score" }   // sample standard deviation

// Median and percentile (7.0+)
$median: { $median: { input: "$score", method: "approximate" } }
$percentile: { $percentile: {
  input: "$responseTime",
  p: [0.5, 0.9, 0.95, 0.99],      // p50, p90, p95, p99
  method: "approximate"
}}
```

---

## Window Functions

### Window Definitions

```javascript
{ $setWindowFields: {
  partitionBy: "$groupField",   // optional: groups for independent windows
  sortBy: { orderField: 1 },   // required for most operators
  output: {
    result: {
      <operator>: <args>,
      window: {
        // Document-based window:
        documents: ["unbounded", "current"]    // from start to current
        documents: [-3, 3]                     // 3 before to 3 after
        documents: ["current", "unbounded"]    // current to end

        // Range-based window (on sortBy field):
        range: [-10, 10]                       // value range on sort field
        range: [-1, 0], unit: "hour"           // time range (date fields)

        // If no window specified: unbounded for ranking, full partition for others
      }
    }
  }
}}
```

### Window Operators

```javascript
// Ranking
$rank:      { $rank: {} }                          // 1, 2, 2, 4 (gaps)
$denseRank: { $denseRank: {} }                     // 1, 2, 2, 3 (no gaps)
$documentNumber: { $documentNumber: {} }            // 1, 2, 3, 4 (unique)

// Position
$shift: { $shift: { output: "$field", by: -1, default: null } }  // lag
$shift: { $shift: { output: "$field", by: 1, default: null } }   // lead

// Running calculations
$sum:     { $sum: "$amount", window: { documents: ["unbounded", "current"] } }
$avg:     { $avg: "$value", window: { range: [-7, 0], unit: "day" } }
$min:     { $min: "$price", window: { documents: ["unbounded", "current"] } }
$max:     { $max: "$price", window: { documents: ["unbounded", "current"] } }
$count:   { $count: {}, window: { documents: ["unbounded", "current"] } }

// Statistical
$stdDevPop:  { $stdDevPop: "$val", window: { documents: [-10, 0] } }
$stdDevSamp: { $stdDevSamp: "$val", window: { documents: [-10, 0] } }

// Linear fill (interpolation)
$linearFill: { $linearFill: "$temperature" }       // fill nulls via interpolation
$locf:       { $locf: "$temperature" }             // last observation carried forward

// Integral and derivative (5.1+)
$integral:   { $integral: { input: "$speed", unit: "hour" } }
$derivative: { $derivative: { input: "$distance", unit: "hour" } }

// Exponential moving average
$expMovingAvg: { $expMovingAvg: { input: "$price", N: 14 } }  // N-period EMA
$expMovingAvg: { $expMovingAvg: { input: "$price", alpha: 0.1 } }  // explicit alpha
```

---

## Atlas Search Integration

### Search Operators

```javascript
// text: full-text search
{ $search: { text: { query: "coffee shop", path: "description", fuzzy: { maxEdits: 2 } } } }

// phrase: exact phrase
{ $search: { phrase: { query: "new york", path: "city", slop: 1 } } }

// autocomplete: type-ahead
{ $search: { autocomplete: { query: "mon", path: "title", tokenOrder: "sequential" } } }

// wildcard
{ $search: { wildcard: { query: "data*", path: "title", allowAnalyzedField: true } } }

// regex
{ $search: { regex: { query: "^[A-Z]{2}-\\d+", path: "code" } } }

// range (numeric/date)
{ $search: { range: { path: "price", gte: 10, lte: 100 } } }

// geo (near point)
{ $search: { geoWithin: { path: "location", geo: { type: "Point", coordinates: [-73.98, 40.75] }, maxDistance: 5000 } } }

// compound: combine operators with must/should/filter/mustNot
{ $search: {
  compound: {
    must: [{ text: { query: "laptop", path: "title" } }],
    should: [{ text: { query: "gaming", path: "description" } }],
    filter: [{ range: { path: "price", lte: 2000 } }],
    mustNot: [{ text: { query: "refurbished", path: "condition" } }],
    minimumShouldMatch: 1
  }
}}

// exists: field exists
{ $search: { exists: { path: "imageUrl" } } }

// near (boosted by proximity to origin value)
{ $search: { near: { path: "releaseDate", origin: ISODate("2024-01-01"), pivot: 7776000000 } } }
// pivot: distance (ms for dates, units for numbers) at which score is halved
```

### Scoring and Highlighting

```javascript
// Custom scoring
{ $search: {
  text: { query: "laptop", path: "title",
    score: {
      boost: { value: 3 },                    // multiply score by 3
      // OR
      boost: { path: "popularity", undefined: 1 }, // boost by field value
      // OR
      constant: { value: 10 },                // fixed score
      // OR
      function: {                              // custom scoring function
        multiply: [
          { score: "relevance" },
          { path: { value: "popularity", undefined: 1 } }
        ]
      }
    }
  }
}}

// Retrieve score and highlights
{ $project: {
  title: 1,
  score: { $meta: "searchScore" },
  highlights: { $meta: "searchHighlights" }
}}
```

### Facet Search

```javascript
// Get facet counts (use $searchMeta for metadata only)
{ $searchMeta: {
  facet: {
    operator: {
      compound: {
        must: [{ text: { query: "laptop", path: "title" } }]
      }
    },
    facets: {
      brandFacet: { type: "string", path: "brand", numBuckets: 10 },
      priceFacet: { type: "number", path: "price", boundaries: [0, 500, 1000, 2000, 5000] },
      dateFacet: { type: "date", path: "listedAt",
        boundaries: [ISODate("2024-01-01"), ISODate("2024-07-01"), ISODate("2025-01-01")] }
    }
  }
}}
// Returns: { count: { total: N }, facet: { brandFacet: { buckets: [...] }, ... } }

// Vector search (Atlas Vector Search)
{ $vectorSearch: {
  index: "vector_index",
  path: "embedding",
  queryVector: [0.1, 0.2, ...],   // embedding of query
  numCandidates: 100,
  limit: 10,
  filter: { category: "electronics" }
}}
```
