# DynamoDB API Reference Patterns

## Table of Contents

- [Item Operations](#item-operations)
  - [GetItem](#getitem)
  - [PutItem](#putitem)
  - [UpdateItem](#updateitem)
  - [DeleteItem](#deleteitem)
- [Query and Scan](#query-and-scan)
  - [Query](#query)
  - [Scan](#scan)
- [Batch Operations](#batch-operations)
  - [BatchGetItem](#batchgetitem)
  - [BatchWriteItem](#batchwriteitem)
- [Transactions](#transactions)
  - [TransactGetItems](#transactgetitems)
  - [TransactWriteItems](#transactwriteitems)
- [PartiQL](#partiql)
- [Expression Syntax](#expression-syntax)
  - [Key Condition Expressions](#key-condition-expressions)
  - [Filter Expressions](#filter-expressions)
  - [Projection Expressions](#projection-expressions)
  - [Condition Expressions](#condition-expressions)
  - [Update Expressions](#update-expressions)
- [Expression Attribute Names and Values](#expression-attribute-names-and-values)
- [Pagination](#pagination)
- [Error Handling Patterns](#error-handling-patterns)

---

## Item Operations

### GetItem

Retrieve a single item by its full primary key (PK + SK).

```python
# Basic get
response = table.get_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'}
)
item = response.get('Item')

# With projection (fetch only specific attributes)
response = table.get_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'},
    ProjectionExpression='#n, email, createdAt',
    ExpressionAttributeNames={'#n': 'name'}  # 'name' is reserved word
)

# Strongly consistent read (default is eventually consistent)
response = table.get_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'},
    ConsistentRead=True
)
```

**Cost**: 1 RCU per 4 KB (strongly consistent), 0.5 RCU per 4 KB (eventually consistent).

**Key points**:
- Returns empty response (no `Item` key) if item doesn't exist — does not throw
- Always specify `ProjectionExpression` when you don't need all attributes
- `ConsistentRead=True` costs 2x but guarantees latest write is visible

### PutItem

Write a complete item. Replaces the entire item if it exists (upsert).

```python
# Basic put (upsert)
table.put_item(
    Item={
        'PK': 'USER#u001',
        'SK': 'METADATA',
        'name': 'Alice',
        'email': 'alice@example.com',
        'createdAt': '2024-03-15T10:00:00Z'
    }
)

# Conditional put — only if item does NOT already exist
table.put_item(
    Item={'PK': 'USER#u001', 'SK': 'METADATA', 'name': 'Alice'},
    ConditionExpression='attribute_not_exists(PK)'
)
# Throws ConditionalCheckFailedException if item exists

# Put with return of old item
response = table.put_item(
    Item={'PK': 'USER#u001', 'SK': 'METADATA', 'name': 'Bob'},
    ReturnValues='ALL_OLD'
)
old_item = response.get('Attributes')  # Previous item, if any
```

**Cost**: 1 WCU per 1 KB.

**Key points**:
- `PutItem` replaces the entire item — it is NOT a partial update
- Use `ConditionExpression='attribute_not_exists(PK)'` for insert-only semantics
- `ReturnValues`: `NONE` (default), `ALL_OLD`

### UpdateItem

Partial update — modify specific attributes without replacing the entire item.

```python
# SET attributes
table.update_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'},
    UpdateExpression='SET #n = :name, updatedAt = :ts',
    ExpressionAttributeNames={'#n': 'name'},
    ExpressionAttributeValues={':name': 'Alice Smith', ':ts': '2024-03-15'}
)

# ADD to a number (atomic increment)
table.update_item(
    Key={'PK': 'USER#u001', 'SK': 'STATS'},
    UpdateExpression='ADD loginCount :one',
    ExpressionAttributeValues={':one': 1}
)

# ADD to a set
table.update_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'},
    UpdateExpression='ADD tags :newTags',
    ExpressionAttributeValues={':newTags': {'python', 'aws'}}
)

# REMOVE attributes
table.update_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'},
    UpdateExpression='REMOVE tempField, oldAttribute'
)

# DELETE elements from a set
table.update_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'},
    UpdateExpression='DELETE tags :removeTags',
    ExpressionAttributeValues={':removeTags': {'old-tag'}}
)

# Conditional update
table.update_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'},
    UpdateExpression='SET #s = :new',
    ConditionExpression='#s = :old',
    ExpressionAttributeNames={'#s': 'status'},
    ExpressionAttributeValues={':new': 'active', ':old': 'pending'}
)

# Return updated item
response = table.update_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'},
    UpdateExpression='SET loginCount = if_not_exists(loginCount, :zero) + :one',
    ExpressionAttributeValues={':zero': 0, ':one': 1},
    ReturnValues='UPDATED_NEW'
)
new_values = response['Attributes']
```

**Cost**: 1 WCU per 1 KB (of the full item, not just updated attributes).

**ReturnValues options**: `NONE`, `ALL_OLD`, `UPDATED_OLD`, `ALL_NEW`, `UPDATED_NEW`

### DeleteItem

Remove a single item by its full primary key.

```python
# Basic delete
table.delete_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'}
)

# Conditional delete — only if item exists and matches condition
table.delete_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'},
    ConditionExpression='#s = :inactive',
    ExpressionAttributeNames={'#s': 'status'},
    ExpressionAttributeValues={':inactive': 'inactive'}
)

# Delete and return the deleted item
response = table.delete_item(
    Key={'PK': 'USER#u001', 'SK': 'METADATA'},
    ReturnValues='ALL_OLD'
)
deleted_item = response.get('Attributes')
```

**Cost**: 1 WCU per 1 KB of the deleted item.

---

## Query and Scan

### Query

Retrieve items from a single partition using the partition key and optional sort key conditions. The most efficient read operation.

```python
from boto3.dynamodb.conditions import Key, Attr

# Basic query — all items in a partition
response = table.query(
    KeyConditionExpression=Key('PK').eq('USER#u001')
)
items = response['Items']

# Sort key conditions
response = table.query(
    KeyConditionExpression=(
        Key('PK').eq('USER#u001') &
        Key('SK').begins_with('ORDER#')
    )
)

# Range query on sort key
response = table.query(
    KeyConditionExpression=(
        Key('PK').eq('USER#u001') &
        Key('SK').between('ORDER#2024-01-01', 'ORDER#2024-12-31')
    )
)

# Reverse sort order (newest first)
response = table.query(
    KeyConditionExpression=Key('PK').eq('USER#u001'),
    ScanIndexForward=False,  # descending sort key order
    Limit=10  # top 10
)

# Query a GSI
response = table.query(
    IndexName='GSI1',
    KeyConditionExpression=(
        Key('GSI1PK').eq('STATUS#active') &
        Key('GSI1SK').begins_with('DATE#2024-03')
    )
)

# With filter expression (applied AFTER read, does not reduce RCU)
response = table.query(
    KeyConditionExpression=Key('PK').eq('USER#u001'),
    FilterExpression=Attr('status').eq('active')
)

# Projection — return only specified attributes
response = table.query(
    KeyConditionExpression=Key('PK').eq('USER#u001'),
    ProjectionExpression='PK, SK, #n, email',
    ExpressionAttributeNames={'#n': 'name'}
)

# Count only (no items returned)
response = table.query(
    KeyConditionExpression=Key('PK').eq('USER#u001'),
    Select='COUNT'
)
count = response['Count']
```

**Sort key operators**: `eq`, `lt`, `lte`, `gt`, `gte`, `between`, `begins_with`

**Cost**: 1 RCU per 4 KB of data read (before filter). Eventually consistent by default.

**Key points**:
- `FilterExpression` does NOT reduce cost — DynamoDB reads first, then filters
- Use `Limit` to cap items per page, not total results
- `ScanIndexForward=False` for descending order
- `Select='COUNT'` returns count without transferring items

### Scan

Read every item in the table or index. Avoid unless you truly need all data.

```python
# Basic scan (avoid in production hot paths)
response = table.scan()
items = response['Items']

# With filter
response = table.scan(
    FilterExpression=Attr('entityType').eq('User') & Attr('status').eq('active'),
    ProjectionExpression='PK, #n, email',
    ExpressionAttributeNames={'#n': 'name'}
)

# Parallel scan
response = table.scan(
    Segment=0,           # this worker's segment (0-based)
    TotalSegments=10,    # total parallel workers
    FilterExpression=Attr('entityType').eq('User')
)

# Scan a specific GSI (may be cheaper if fewer items/smaller projection)
response = table.scan(
    IndexName='GSI1',
    FilterExpression=Attr('GSI1PK').begins_with('STATUS#')
)

# Rate-limited scan
response = table.scan(Limit=100)  # read 100 items per page
while 'LastEvaluatedKey' in response:
    time.sleep(0.5)  # throttle to avoid capacity spikes
    response = table.scan(
        Limit=100,
        ExclusiveStartKey=response['LastEvaluatedKey']
    )
```

**Cost**: Reads every item. 1 RCU per 4 KB of total data scanned.

---

## Batch Operations

### BatchGetItem

Retrieve up to 100 items across one or more tables in a single call.

```python
# Using the resource interface
response = dynamodb.batch_get_item(
    RequestItems={
        'MyTable': {
            'Keys': [
                {'PK': 'USER#u001', 'SK': 'METADATA'},
                {'PK': 'USER#u002', 'SK': 'METADATA'},
                {'PK': 'ORDER#o001', 'SK': 'METADATA'},
            ],
            'ProjectionExpression': 'PK, SK, #n, email',
            'ExpressionAttributeNames': {'#n': 'name'},
            'ConsistentRead': False
        }
    }
)
items = response['Responses']['MyTable']

# Handle unprocessed keys (throttled items)
unprocessed = response.get('UnprocessedKeys', {})
while unprocessed:
    time.sleep(0.5)  # backoff
    response = dynamodb.batch_get_item(RequestItems=unprocessed)
    items.extend(response['Responses'].get('MyTable', []))
    unprocessed = response.get('UnprocessedKeys', {})
```

**Limits**: 100 items, 16 MB total response.

**Key points**:
- No ordering guarantee — items may return in any order
- Always handle `UnprocessedKeys` (throttled items)
- Items not found are silently omitted (no error)

### BatchWriteItem

Write (put or delete) up to 25 items across one or more tables.

```python
# Batch write
with table.batch_writer() as batch:
    for item in items:
        batch.put_item(Item=item)

# Low-level API (put and delete mixed)
response = dynamodb.batch_write_item(
    RequestItems={
        'MyTable': [
            {'PutRequest': {'Item': {'PK': 'USER#u001', 'SK': 'METADATA', 'name': 'Alice'}}},
            {'PutRequest': {'Item': {'PK': 'USER#u002', 'SK': 'METADATA', 'name': 'Bob'}}},
            {'DeleteRequest': {'Key': {'PK': 'USER#u003', 'SK': 'METADATA'}}},
        ]
    }
)

# Handle unprocessed items
unprocessed = response.get('UnprocessedItems', {})
retries = 0
while unprocessed and retries < 5:
    time.sleep(2 ** retries * 0.1)
    response = dynamodb.batch_write_item(RequestItems=unprocessed)
    unprocessed = response.get('UnprocessedItems', {})
    retries += 1
```

**Limits**: 25 items, 16 MB total request, 400 KB per item.

**Key points**:
- No UpdateItem support — only Put and Delete
- No condition expressions — operations are unconditional
- `batch_writer()` (high-level) auto-handles batching and unprocessed items
- Items in the same batch can target the same table
- Two operations in the same batch cannot target the same item

---

## Transactions

### TransactGetItems

ACID-compliant read of up to 100 items. All items are read atomically — you get a consistent snapshot.

```python
response = client.transact_get_items(
    TransactItems=[
        {'Get': {
            'TableName': 'MyTable',
            'Key': {'PK': {'S': 'USER#u001'}, 'SK': {'S': 'METADATA'}}
        }},
        {'Get': {
            'TableName': 'MyTable',
            'Key': {'PK': {'S': 'ACCOUNT#a001'}, 'SK': {'S': 'BALANCE'}}
        }}
    ]
)
items = [r.get('Item') for r in response['Responses']]
```

**Cost**: 2 RCU per 4 KB per item (2x standard read).

### TransactWriteItems

ACID-compliant write of up to 100 items. All operations succeed or all fail.

```python
# Transfer money between accounts
client.transact_write_items(
    TransactItems=[
        # Debit source
        {'Update': {
            'TableName': 'MyTable',
            'Key': {'PK': {'S': 'ACCOUNT#a001'}, 'SK': {'S': 'BALANCE'}},
            'UpdateExpression': 'SET balance = balance - :amount',
            'ConditionExpression': 'balance >= :amount',
            'ExpressionAttributeValues': {':amount': {'N': '100'}},
        }},
        # Credit destination
        {'Update': {
            'TableName': 'MyTable',
            'Key': {'PK': {'S': 'ACCOUNT#a002'}, 'SK': {'S': 'BALANCE'}},
            'UpdateExpression': 'SET balance = balance + :amount',
            'ExpressionAttributeValues': {':amount': {'N': '100'}},
        }},
        # Write transfer record
        {'Put': {
            'TableName': 'MyTable',
            'Item': {
                'PK': {'S': 'TRANSFER#t001'}, 'SK': {'S': 'METADATA'},
                'from': {'S': 'a001'}, 'to': {'S': 'a002'},
                'amount': {'N': '100'}, 'ts': {'S': '2024-03-15T10:00:00Z'}
            },
            'ConditionExpression': 'attribute_not_exists(PK)'  # idempotency
        }}
    ],
    ClientRequestToken='unique-idempotency-token-abc123'  # optional idempotency
)

# ConditionCheck — assert without modifying (useful for validation)
{'ConditionCheck': {
    'TableName': 'MyTable',
    'Key': {'PK': {'S': 'USER#u001'}, 'SK': {'S': 'METADATA'}},
    'ConditionExpression': '#s = :active',
    'ExpressionAttributeNames': {'#s': 'status'},
    'ExpressionAttributeValues': {':active': {'S': 'active'}}
}}
```

**Operations**: `Put`, `Update`, `Delete`, `ConditionCheck`

**Cost**: 2 WCU per 1 KB per item (2x standard write).

**Limits**:
- 100 items max, 4 MB total
- All items must be in the same region
- No two operations can target the same item (PK+SK)
- `ClientRequestToken` provides idempotency for 10 minutes

---

## PartiQL

SQL-compatible query language for DynamoDB. Useful for ad-hoc queries and familiar syntax.

```python
# SELECT (equivalent to GetItem)
response = client.execute_statement(
    Statement="SELECT * FROM MyTable WHERE PK = 'USER#u001' AND SK = 'METADATA'"
)

# SELECT with filter
response = client.execute_statement(
    Statement="SELECT name, email FROM MyTable WHERE PK = ? AND begins_with(SK, ?)",
    Parameters=[{'S': 'USER#u001'}, {'S': 'ORDER#'}]
)

# INSERT
client.execute_statement(
    Statement="INSERT INTO MyTable VALUE {'PK': ?, 'SK': ?, 'name': ?}",
    Parameters=[{'S': 'USER#u002'}, {'S': 'METADATA'}, {'S': 'Bob'}]
)

# UPDATE
client.execute_statement(
    Statement="UPDATE MyTable SET name = ? WHERE PK = ? AND SK = ?",
    Parameters=[{'S': 'Alice Smith'}, {'S': 'USER#u001'}, {'S': 'METADATA'}]
)

# DELETE
client.execute_statement(
    Statement="DELETE FROM MyTable WHERE PK = ? AND SK = ?",
    Parameters=[{'S': 'USER#u001'}, {'S': 'METADATA'}]
)

# Batch statements (up to 25)
response = client.batch_execute_statement(
    Statements=[
        {
            'Statement': "SELECT * FROM MyTable WHERE PK = ? AND SK = ?",
            'Parameters': [{'S': 'USER#u001'}, {'S': 'METADATA'}]
        },
        {
            'Statement': "SELECT * FROM MyTable WHERE PK = ? AND SK = ?",
            'Parameters': [{'S': 'USER#u002'}, {'S': 'METADATA'}]
        }
    ]
)

# Transaction statements
response = client.execute_transaction(
    TransactStatements=[
        {
            'Statement': "UPDATE MyTable SET balance = balance - 100 WHERE PK = ? AND SK = ?",
            'Parameters': [{'S': 'ACCOUNT#a001'}, {'S': 'BALANCE'}]
        },
        {
            'Statement': "UPDATE MyTable SET balance = balance + 100 WHERE PK = ? AND SK = ?",
            'Parameters': [{'S': 'ACCOUNT#a002'}, {'S': 'BALANCE'}]
        }
    ]
)
```

**Key points**:
- PartiQL SELECT on a key condition uses Query (efficient)
- PartiQL SELECT without key condition uses Scan (expensive!)
- Always parameterize with `?` placeholders — never concatenate values
- Same cost and limits as equivalent DynamoDB API calls

---

## Expression Syntax

### Key Condition Expressions

Used in `Query` to specify which items to retrieve. Must include partition key equality and optional sort key condition.

```
PK = :pk                                    # exact PK match (required)
PK = :pk AND SK = :sk                       # exact PK + SK match
PK = :pk AND SK < :sk                       # PK + SK less than
PK = :pk AND SK <= :sk                      # PK + SK less than or equal
PK = :pk AND SK > :sk                       # PK + SK greater than
PK = :pk AND SK >= :sk                      # PK + SK greater than or equal
PK = :pk AND SK BETWEEN :sk1 AND :sk2       # PK + SK in range (inclusive)
PK = :pk AND begins_with(SK, :prefix)       # PK + SK starts with prefix
```

### Filter Expressions

Applied AFTER data is read, BEFORE results are returned. Does NOT reduce RCU cost.

```
# Comparison
status = :active
price > :minPrice
age BETWEEN :min AND :max

# Logical operators
status = :active AND price < :maxPrice
status = :active OR status = :pending
NOT contains(tags, :excluded)

# Functions
attribute_exists(email)                      # attribute is present
attribute_not_exists(deletedAt)              # attribute is absent
attribute_type(age, :type)                   # type check (:type = "N", "S", "B", etc.)
begins_with(#name, :prefix)                  # string/binary starts with
contains(tags, :tag)                         # string contains substring, or set contains element
size(description) > :maxLen                  # length of string/binary/list/map/set

# IN operator
#status IN (:s1, :s2, :s3)                   # value is one of the listed values
```

### Projection Expressions

Specify which attributes to return. Reduces network transfer but still reads full item (same RCU).

```python
# Simple attributes
ProjectionExpression='PK, SK, #n, email'

# Nested attributes (map)
ProjectionExpression='address.city, address.zip'

# List elements
ProjectionExpression='orders[0], orders[1]'

# Combined
ProjectionExpression='#n, address.city, tags[0]'
```

### Condition Expressions

Used in `PutItem`, `UpdateItem`, `DeleteItem` to conditionally execute the operation.

```
# Insert only (item must not exist)
attribute_not_exists(PK)

# Update only (item must exist)
attribute_exists(PK)

# Optimistic locking
version = :expectedVersion

# Complex conditions
attribute_exists(PK) AND #status = :active AND price < :maxPrice

# Prevent overwrite of newer data
updatedAt < :newTimestamp
```

### Update Expressions

Used in `UpdateItem` to modify attributes. Four clauses: `SET`, `REMOVE`, `ADD`, `DELETE`.

```
# SET — assign values
SET #name = :name
SET #name = :name, email = :email                     # multiple attributes
SET orderCount = orderCount + :one                     # arithmetic
SET #name = if_not_exists(#name, :default)              # default value
SET updatedAt = :now
SET address.city = :city                               # nested attribute
SET orders[0].status = :shipped                        # list element

# REMOVE — delete attributes
REMOVE tempField
REMOVE address.zip, oldAttribute                       # multiple
REMOVE orders[2]                                       # remove list element

# ADD — atomic increment (numbers) or add to set
ADD viewCount :one                                     # increment number
ADD tags :newTags                                      # add to set (String Set, Number Set)

# DELETE — remove elements from a set
DELETE tags :removeTags                                # remove from set

# Combined (one of each clause per expression)
SET #name = :name, updatedAt = :now REMOVE tempField ADD viewCount :one
```

**`list_append` function**:
```
SET orders = list_append(orders, :newOrder)             # append to end
SET orders = list_append(:newOrder, orders)             # prepend to start
```

---

## Expression Attribute Names and Values

### When to use `ExpressionAttributeNames`

Required when the attribute name:
- Is a DynamoDB reserved word (`name`, `status`, `data`, `comment`, `count`, `size`, `type`, `key`, `value`, `timestamp`, `date`, `year`, `month`, `day`, `hour`, etc.)
- Contains a dot (`.`) — which DynamoDB interprets as nested access
- Starts with a number

```python
ExpressionAttributeNames = {
    '#n': 'name',           # reserved word
    '#s': 'status',         # reserved word
    '#d': 'data',           # reserved word
    '#k': 'some.key',       # contains dot
    '#t': 'type',           # reserved word
}
```

### `ExpressionAttributeValues`

Always prefix with `:`. Types are inferred from Python types when using the resource interface:

```python
ExpressionAttributeValues = {
    ':name': 'Alice',           # String
    ':age': 30,                 # Number
    ':active': True,            # Boolean
    ':tags': {'python', 'aws'}, # String Set
    ':data': b'\x00\x01',      # Binary
    ':address': {'city': 'SF'}, # Map
    ':items': [1, 2, 3],       # List
    ':none': None,              # Null
}
```

---

## Pagination

All `Query` and `Scan` operations return at most 1 MB of data per call. Use `LastEvaluatedKey` for pagination.

```python
def query_all(table, **kwargs):
    """Paginate through all results."""
    items = []
    response = table.query(**kwargs)
    items.extend(response['Items'])
    while 'LastEvaluatedKey' in response:
        response = table.query(
            **kwargs,
            ExclusiveStartKey=response['LastEvaluatedKey']
        )
        items.extend(response['Items'])
    return items

# With limit per page (for UI pagination)
def query_page(table, page_size, last_key=None, **kwargs):
    params = {**kwargs, 'Limit': page_size}
    if last_key:
        params['ExclusiveStartKey'] = last_key
    response = table.query(**params)
    return {
        'items': response['Items'],
        'next_key': response.get('LastEvaluatedKey'),
        'has_more': 'LastEvaluatedKey' in response
    }
```

**Key points**:
- `Limit` limits items evaluated, not items returned (after filter, you may get fewer)
- `LastEvaluatedKey` is opaque — pass it back exactly
- Do NOT use `Limit` as a page size when using `FilterExpression` — you may get 0 results with a non-null `LastEvaluatedKey`
- For consistent page sizes with filters, loop until you have enough items or no more pages

---

## Error Handling Patterns

### Idempotent writes

```python
import uuid

def create_order(user_id, items, idempotency_key=None):
    idempotency_key = idempotency_key or str(uuid.uuid4())
    try:
        table.put_item(
            Item={
                'PK': f'ORDER#{idempotency_key}',
                'SK': 'METADATA',
                'userId': user_id,
                'items': items,
                'status': 'created'
            },
            ConditionExpression='attribute_not_exists(PK)'
        )
    except ClientError as e:
        if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
            return  # idempotent — order already exists, no error
        raise
```

### Optimistic locking

```python
def update_with_lock(table, key, updates, expected_version):
    try:
        response = table.update_item(
            Key=key,
            UpdateExpression='SET ' + ', '.join(f'#{k} = :{k}' for k in updates) + ', version = :newVersion',
            ConditionExpression='version = :expectedVersion',
            ExpressionAttributeNames={f'#{k}': k for k in updates},
            ExpressionAttributeValues={
                **{f':{k}': v for k, v in updates.items()},
                ':expectedVersion': expected_version,
                ':newVersion': expected_version + 1
            },
            ReturnValues='ALL_NEW'
        )
        return response['Attributes']
    except ClientError as e:
        if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
            raise ConcurrencyError("Item was modified by another process")
        raise
```

### Exponential backoff with jitter

```python
import random, time

def with_backoff(func, max_retries=8, base_delay=0.05):
    for attempt in range(max_retries):
        try:
            return func()
        except ClientError as e:
            if e.response['Error']['Code'] not in [
                'ProvisionedThroughputExceededException',
                'ThrottlingException',
                'InternalServerError'
            ]:
                raise  # non-retryable error
            if attempt == max_retries - 1:
                raise
            delay = min(base_delay * (2 ** attempt), 30)
            jitter = random.uniform(0, delay)
            time.sleep(jitter)
```
