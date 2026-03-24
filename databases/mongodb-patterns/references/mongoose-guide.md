# Mongoose Comprehensive Guide

## Table of Contents

- [Schema Definitions](#schema-definitions)
  - [Schema Types](#schema-types)
  - [Schema Options](#schema-options)
  - [Custom Validation](#custom-validation)
  - [Nested Schemas and Subdocuments](#nested-schemas-and-subdocuments)
- [Virtuals](#virtuals)
  - [Getter Virtuals](#getter-virtuals)
  - [Setter Virtuals](#setter-virtuals)
  - [Virtual Populate](#virtual-populate)
- [Methods and Statics](#methods-and-statics)
  - [Instance Methods](#instance-methods)
  - [Static Methods](#static-methods)
  - [Query Helpers](#query-helpers)
- [Middleware (Hooks)](#middleware-hooks)
  - [Document Middleware](#document-middleware)
  - [Query Middleware](#query-middleware)
  - [Aggregate Middleware](#aggregate-middleware)
  - [Error Handling Middleware](#error-handling-middleware)
- [Population](#population)
  - [Basic Population](#basic-population)
  - [Nested Population](#nested-population)
  - [Conditional Population](#conditional-population)
  - [Virtual Population](#virtual-population)
- [Discriminators](#discriminators)
  - [Basic Discriminators](#basic-discriminators)
  - [Embedded Discriminators](#embedded-discriminators)
- [Lean Queries](#lean-queries)
  - [When to Use lean()](#when-to-use-lean)
  - [Lean with Plugins](#lean-with-plugins)
- [Transactions with Mongoose](#transactions-with-mongoose)
  - [Using withTransaction()](#using-withtransaction)
  - [Manual Transaction Control](#manual-transaction-control)
  - [Transaction Retry Logic](#transaction-retry-logic)
- [Plugins](#plugins)
  - [Writing a Plugin](#writing-a-plugin)
  - [Global Plugins](#global-plugins)
  - [Popular Plugins](#popular-plugins)
- [Connection Management](#connection-management)
  - [Connection Options](#connection-options)
  - [Multiple Connections](#multiple-connections)
  - [Connection Events](#connection-events)
  - [Connection Pooling](#connection-pooling)
- [Migration Strategies](#migration-strategies)
  - [Schema Versioning](#schema-versioning)
  - [Using migrate-mongo](#using-migrate-mongo)
  - [Zero-Downtime Migrations](#zero-downtime-migrations)
- [TypeScript Integration](#typescript-integration)
  - [Schema Type Inference](#schema-type-inference)
  - [Typed Methods and Statics](#typed-methods-and-statics)
  - [Typed Virtuals and Query Helpers](#typed-virtuals-and-query-helpers)
  - [Generic Document Type](#generic-document-type)

---

## Schema Definitions

### Schema Types

```typescript
import mongoose, { Schema, model, Types } from 'mongoose';

const productSchema = new Schema({
  // String with validators
  name: {
    type: String,
    required: [true, 'Product name is required'],
    trim: true,
    minlength: [2, 'Name must be at least 2 characters'],
    maxlength: [200, 'Name cannot exceed 200 characters'],
    index: true
  },

  // Number with min/max
  price: { type: Number, required: true, min: [0, 'Price must be positive'] },

  // Boolean with default
  isActive: { type: Boolean, default: true },

  // Date with default to now
  createdAt: { type: Date, default: Date.now, immutable: true },

  // ObjectId reference
  categoryId: { type: Schema.Types.ObjectId, ref: 'Category', required: true },

  // Enum
  status: {
    type: String,
    enum: { values: ['draft', 'published', 'archived'], message: '{VALUE} is not a valid status' },
    default: 'draft'
  },

  // Array of strings
  tags: [{ type: String, lowercase: true, trim: true }],

  // Array of subdocuments
  variants: [{
    sku: { type: String, required: true },
    color: String,
    size: String,
    stock: { type: Number, default: 0, min: 0 }
  }],

  // Map (dynamic keys)
  attributes: { type: Map, of: String },

  // Mixed type (schemaless — use sparingly)
  metadata: { type: Schema.Types.Mixed },

  // Decimal128 for financial precision
  costPrice: { type: Schema.Types.Decimal128 },

  // Buffer for binary data
  thumbnail: Buffer,

  // UUID (Mongoose 8+)
  externalId: { type: Schema.Types.UUID }
});
```

### Schema Options

```typescript
const userSchema = new Schema({
  email: { type: String, required: true, unique: true },
  name: String,
  role: { type: String, default: 'user' }
}, {
  timestamps: true,              // adds createdAt, updatedAt
  collection: 'app_users',      // explicit collection name
  versionKey: '__v',             // default; set false to disable
  strict: true,                  // ignore fields not in schema (default)
  strictQuery: true,             // strict mode for queries (Mongoose 7+)
  toJSON: {
    virtuals: true,              // include virtuals in JSON output
    transform: (doc, ret) => {
      delete ret.__v;
      ret.id = ret._id;
      delete ret._id;
      return ret;
    }
  },
  toObject: { virtuals: true },
  optimisticConcurrency: true,   // enable optimistic locking via __v
  read: 'secondaryPreferred',   // default read preference
  writeConcern: { w: 'majority' },
  autoIndex: process.env.NODE_ENV !== 'production',  // disable in prod
  selectPopulatedPaths: false    // don't auto-select populated paths
});
```

### Custom Validation

```typescript
const orderSchema = new Schema({
  items: {
    type: [{ productId: Schema.Types.ObjectId, qty: Number, price: Number }],
    validate: {
      validator: (items: any[]) => items.length > 0,
      message: 'Order must have at least one item'
    }
  },
  email: {
    type: String,
    validate: {
      validator: (v: string) => /^[\w.-]+@[\w.-]+\.\w+$/.test(v),
      message: (props: any) => `${props.value} is not a valid email`
    }
  },
  startDate: Date,
  endDate: {
    type: Date,
    validate: {
      validator: function(this: any, value: Date) {
        return value > this.startDate;
      },
      message: 'End date must be after start date'
    }
  }
});

// Async validator
userSchema.path('email').validate({
  validator: async function(email: string) {
    const count = await mongoose.models.User.countDocuments({ email });
    return count === 0;
  },
  message: 'Email already exists'
});
```

### Nested Schemas and Subdocuments

```typescript
// Reusable schema for addresses
const addressSchema = new Schema({
  street: { type: String, required: true },
  city: { type: String, required: true },
  state: String,
  zip: { type: String, required: true },
  country: { type: String, default: 'US' }
}, { _id: false });  // no _id for subdocuments

const customerSchema = new Schema({
  name: String,
  billingAddress: { type: addressSchema, required: true },
  shippingAddresses: [addressSchema],  // array of subdocuments
  // Nested path (not a subdocument — no middleware, no _id)
  preferences: {
    newsletter: { type: Boolean, default: false },
    language: { type: String, default: 'en' }
  }
});

// Subdocument operations
const customer = await Customer.findById(id);
customer.shippingAddresses.push({ street: '456 Oak', city: 'LA', zip: '90001' });
const addr = customer.shippingAddresses.id(subdocId);  // find by _id
addr.remove();  // remove subdocument
await customer.save();
```

---

## Virtuals

### Getter Virtuals

```typescript
const userSchema = new Schema({
  firstName: String,
  lastName: String,
  birthDate: Date
});

// Computed property — not stored in database
userSchema.virtual('fullName').get(function() {
  return `${this.firstName} ${this.lastName}`;
});

userSchema.virtual('age').get(function() {
  if (!this.birthDate) return null;
  const diff = Date.now() - this.birthDate.getTime();
  return Math.floor(diff / (365.25 * 24 * 60 * 60 * 1000));
});

// Include in JSON/Object output
userSchema.set('toJSON', { virtuals: true });
userSchema.set('toObject', { virtuals: true });
```

### Setter Virtuals

```typescript
userSchema.virtual('fullName')
  .get(function() { return `${this.firstName} ${this.lastName}`; })
  .set(function(fullName: string) {
    const [first, ...rest] = fullName.split(' ');
    this.firstName = first;
    this.lastName = rest.join(' ');
  });

// Usage
const user = new User({ fullName: 'Jane Doe' });
// user.firstName === 'Jane', user.lastName === 'Doe'
```

### Virtual Populate

```typescript
// Author schema
const authorSchema = new Schema({ name: String });

// Virtual field — no foreign key stored on author
authorSchema.virtual('books', {
  ref: 'Book',
  localField: '_id',
  foreignField: 'authorId',
  options: { sort: { publishedDate: -1 }, limit: 10 }
});

// Book schema
const bookSchema = new Schema({
  title: String,
  authorId: { type: Schema.Types.ObjectId, ref: 'Author' }
});

// Usage
const author = await Author.findById(id).populate('books');
// author.books = [{ title: 'Book 1', ... }, ...]

// Count virtual
authorSchema.virtual('bookCount', {
  ref: 'Book',
  localField: '_id',
  foreignField: 'authorId',
  count: true
});
```

---

## Methods and Statics

### Instance Methods

```typescript
const userSchema = new Schema({
  email: String,
  password: String,
  loginAttempts: { type: Number, default: 0 },
  lockUntil: Date
});

// Instance method — called on document instances
userSchema.methods.comparePassword = async function(candidatePassword: string) {
  return bcrypt.compare(candidatePassword, this.password);
};

userSchema.methods.isLocked = function() {
  return this.lockUntil && this.lockUntil > new Date();
};

userSchema.methods.incrementLoginAttempts = async function() {
  if (this.lockUntil && this.lockUntil < new Date()) {
    return this.updateOne({
      $set: { loginAttempts: 1 },
      $unset: { lockUntil: 1 }
    });
  }
  const updates: any = { $inc: { loginAttempts: 1 } };
  if (this.loginAttempts + 1 >= 5) {
    updates.$set = { lockUntil: new Date(Date.now() + 2 * 60 * 60 * 1000) };
  }
  return this.updateOne(updates);
};

// Usage
const user = await User.findOne({ email });
if (user.isLocked()) throw new Error('Account locked');
const isMatch = await user.comparePassword(password);
```

### Static Methods

```typescript
// Static methods — called on the Model
userSchema.statics.findByEmail = function(email: string) {
  return this.findOne({ email: email.toLowerCase() });
};

userSchema.statics.findActiveUsers = function(limit = 50) {
  return this.find({ isActive: true })
    .sort({ lastLogin: -1 })
    .limit(limit)
    .select('name email lastLogin');
};

userSchema.statics.getStats = function() {
  return this.aggregate([
    { $group: {
      _id: '$role',
      count: { $sum: 1 },
      avgAge: { $avg: '$age' }
    }}
  ]);
};

// Usage
const user = await User.findByEmail('alice@example.com');
const stats = await User.getStats();
```

### Query Helpers

```typescript
// Query helpers — chainable query methods
userSchema.query.byRole = function(role: string) {
  return this.where({ role });
};

userSchema.query.active = function() {
  return this.where({ isActive: true, deletedAt: null });
};

userSchema.query.recent = function(days = 30) {
  const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000);
  return this.where({ createdAt: { $gte: since } });
};

// Usage — chain helpers
const admins = await User.find()
  .byRole('admin')
  .active()
  .recent(7)
  .sort({ name: 1 });
```

---

## Middleware (Hooks)

### Document Middleware

```typescript
// Pre-save: hash password before saving
userSchema.pre('save', async function(next) {
  if (!this.isModified('password')) return next();
  this.password = await bcrypt.hash(this.password, 12);
  next();
});

// Post-save: send welcome email
userSchema.post('save', async function(doc) {
  if (doc.isNew) {
    await emailService.sendWelcome(doc.email);
  }
});

// Pre-validate
userSchema.pre('validate', function(next) {
  if (this.role === 'admin' && !this.adminCode) {
    this.invalidate('adminCode', 'Admin code required for admin role');
  }
  next();
});

// Pre-remove (deleteOne in Mongoose 8+)
userSchema.pre('deleteOne', { document: true, query: false }, async function() {
  await mongoose.model('Post').deleteMany({ authorId: this._id });
  await mongoose.model('Comment').deleteMany({ userId: this._id });
});
```

### Query Middleware

```typescript
// Pre-find: automatically exclude soft-deleted documents
userSchema.pre(/^find/, function(next) {
  // 'this' is the query
  this.where({ deletedAt: null });
  next();
});

// Pre-findOneAndUpdate: update timestamp
userSchema.pre('findOneAndUpdate', function(next) {
  this.set({ updatedAt: new Date() });
  next();
});

// Post-findOneAndDelete: cleanup related data
userSchema.post('findOneAndDelete', async function(doc) {
  if (doc) {
    await AuditLog.create({ action: 'user_deleted', userId: doc._id });
  }
});

// Pre-updateMany
userSchema.pre('updateMany', function(next) {
  this.set({ updatedAt: new Date() });
  next();
});
```

### Aggregate Middleware

```typescript
// Pre-aggregate: add $match for soft deletes
userSchema.pre('aggregate', function(next) {
  this.pipeline().unshift({ $match: { deletedAt: null } });
  next();
});
```

### Error Handling Middleware

```typescript
// Handle duplicate key errors globally
userSchema.post('save', function(error: any, doc: any, next: Function) {
  if (error.name === 'MongoServerError' && error.code === 11000) {
    const field = Object.keys(error.keyPattern)[0];
    next(new Error(`${field} already exists`));
  } else {
    next(error);
  }
});

// Handle validation errors
userSchema.post('validate', function(error: any, doc: any, next: Function) {
  if (error.name === 'ValidationError') {
    const messages = Object.values(error.errors).map((e: any) => e.message);
    next(new Error(`Validation failed: ${messages.join(', ')}`));
  } else {
    next(error);
  }
});
```

---

## Population

### Basic Population

```typescript
const postSchema = new Schema({
  title: String,
  content: String,
  author: { type: Schema.Types.ObjectId, ref: 'User' },
  comments: [{ type: Schema.Types.ObjectId, ref: 'Comment' }]
});

// Populate single ref
const post = await Post.findById(id).populate('author');

// Populate with field selection
const post = await Post.findById(id).populate('author', 'name email -_id');

// Populate multiple paths
const post = await Post.findById(id)
  .populate('author', 'name')
  .populate('comments');

// Populate with options
const post = await Post.findById(id).populate({
  path: 'comments',
  match: { isApproved: true },
  select: 'text author createdAt',
  options: { sort: { createdAt: -1 }, limit: 10 },
  populate: { path: 'author', select: 'name avatar' }
});
```

### Nested Population

```typescript
// Deep populate: post → comments → author
const post = await Post.findById(id).populate({
  path: 'comments',
  populate: {
    path: 'author',
    select: 'name avatar',
    populate: { path: 'team', select: 'name' }
  }
});
```

### Conditional Population

```typescript
// Populate based on condition
const posts = await Post.find({ status: 'published' }).populate({
  path: 'author',
  match: { isActive: true },  // only populate active authors
  select: 'name'
});
// author will be null if match fails

// Dynamic ref (populate from different collections)
const activitySchema = new Schema({
  targetType: { type: String, enum: ['Post', 'Comment', 'User'] },
  targetId: { type: Schema.Types.ObjectId, refPath: 'targetType' }
});

const activity = await Activity.findById(id).populate('targetId');
// Populates from Post, Comment, or User collection based on targetType
```

### Virtual Population

```typescript
// No foreign key on parent — use virtual populate
const bandSchema = new Schema({ name: String });
bandSchema.virtual('members', {
  ref: 'Person',
  localField: '_id',
  foreignField: 'bandId',
  justOne: false,              // array of docs
  options: { sort: { name: 1 } }
});

const band = await Band.findOne({ name: 'The Beatles' }).populate('members');
```

---

## Discriminators

### Basic Discriminators

```typescript
// Base schema — shared fields
const eventSchema = new Schema({
  date: { type: Date, required: true },
  location: String
}, { discriminatorKey: 'eventType' });

const Event = model('Event', eventSchema);

// Discriminator schemas — add specific fields
const Concert = Event.discriminator('Concert', new Schema({
  artist: { type: String, required: true },
  ticketPrice: Number,
  headliner: Boolean
}));

const Conference = Event.discriminator('Conference', new Schema({
  speakers: [String],
  topic: { type: String, required: true },
  maxAttendees: Number
}));

// All stored in same 'events' collection with discriminatorKey
const concert = await Concert.create({
  date: new Date(), location: 'Madison Square Garden',
  artist: 'Band X', ticketPrice: 75
});
// Stored: { eventType: 'Concert', date: ..., artist: 'Band X', ... }

// Query all events
const allEvents = await Event.find();

// Query only concerts
const concerts = await Concert.find({ ticketPrice: { $lt: 100 } });
```

### Embedded Discriminators

```typescript
// Discriminators within arrays
const orderSchema = new Schema({ customer: String });

const itemSchema = new Schema({}, { discriminatorKey: 'itemType' });

const productItem = new Schema({ productId: Schema.Types.ObjectId, qty: Number });
const serviceItem = new Schema({ serviceId: Schema.Types.ObjectId, hours: Number });

const itemsArray = orderSchema.path('items');
itemsArray.discriminator('product', productItem);
itemsArray.discriminator('service', serviceItem);

// Mixed array of product and service items in one order
const order = await Order.create({
  customer: 'Acme Corp',
  items: [
    { itemType: 'product', productId: pid, qty: 5 },
    { itemType: 'service', serviceId: sid, hours: 10 }
  ]
});
```

---

## Lean Queries

### When to Use lean()

```typescript
// lean() returns plain JavaScript objects instead of Mongoose documents
// 2-5x faster, uses less memory — no getters/setters, virtuals, save()

// GOOD: read-only API responses
app.get('/api/users', async (req, res) => {
  const users = await User.find({ isActive: true })
    .lean()
    .select('name email role')
    .sort({ name: 1 });
  res.json(users);  // plain objects, no Mongoose overhead
});

// BAD: when you need to modify and save
const user = await User.findById(id).lean();
user.name = 'New Name';
await user.save();  // ERROR: save() doesn't exist on lean objects

// GOOD: when you need to modify and save
const user = await User.findById(id);  // no lean()
user.name = 'New Name';
await user.save();

// lean() with virtuals (requires mongoose-lean-virtuals plugin)
const users = await User.find().lean({ virtuals: true });
```

### Lean with Plugins

```typescript
import mongooseLeanVirtuals from 'mongoose-lean-virtuals';
import mongooseLeanGetters from 'mongoose-lean-getters';
import mongooseLeanDefaults from 'mongoose-lean-defaults';

userSchema.plugin(mongooseLeanVirtuals);
userSchema.plugin(mongooseLeanGetters);
userSchema.plugin(mongooseLeanDefaults);

// Now lean queries include virtuals, getters, and defaults
const users = await User.find()
  .lean({ virtuals: true, getters: true, defaults: true });
```

---

## Transactions with Mongoose

### Using withTransaction()

```typescript
// Recommended: withTransaction() handles retries automatically
const session = await mongoose.startSession();
try {
  const result = await session.withTransaction(async () => {
    const sender = await Account.findOneAndUpdate(
      { _id: senderId, balance: { $gte: amount } },
      { $inc: { balance: -amount } },
      { new: true, session }
    );
    if (!sender) throw new Error('Insufficient funds');

    await Account.findOneAndUpdate(
      { _id: receiverId },
      { $inc: { balance: amount } },
      { session }
    );

    await Transaction.create([{
      from: senderId,
      to: receiverId,
      amount,
      date: new Date()
    }], { session });

    return { success: true, newBalance: sender.balance };
  });
  return result;
} finally {
  await session.endSession();
}
```

### Manual Transaction Control

```typescript
const session = await mongoose.startSession();
session.startTransaction({
  readConcern: { level: 'snapshot' },
  writeConcern: { w: 'majority' },
  readPreference: 'primary',
  maxCommitTimeMS: 5000
});

try {
  // All operations must pass { session }
  const order = await Order.create([{ items, total }], { session });

  await Inventory.bulkWrite(
    items.map(item => ({
      updateOne: {
        filter: { _id: item.productId, stock: { $gte: item.qty } },
        update: { $inc: { stock: -item.qty } }
      }
    })),
    { session }
  );

  await session.commitTransaction();
} catch (error) {
  await session.abortTransaction();
  throw error;
} finally {
  await session.endSession();
}
```

### Transaction Retry Logic

```typescript
async function runWithRetry(fn: () => Promise<any>, maxRetries = 3) {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    const session = await mongoose.startSession();
    try {
      const result = await session.withTransaction(fn);
      return result;
    } catch (error: any) {
      // TransientTransactionError: safe to retry
      if (error.hasErrorLabel?.('TransientTransactionError') && attempt < maxRetries) {
        console.warn(`Transaction retry ${attempt}/${maxRetries}`);
        continue;
      }
      throw error;
    } finally {
      await session.endSession();
    }
  }
}
```

---

## Plugins

### Writing a Plugin

```typescript
// Soft delete plugin
function softDeletePlugin(schema: Schema) {
  schema.add({
    deletedAt: { type: Date, default: null },
    deletedBy: { type: Schema.Types.ObjectId, ref: 'User', default: null }
  });

  schema.methods.softDelete = function(userId?: string) {
    this.deletedAt = new Date();
    this.deletedBy = userId;
    return this.save();
  };

  schema.methods.restore = function() {
    this.deletedAt = null;
    this.deletedBy = null;
    return this.save();
  };

  schema.statics.findActive = function(filter = {}) {
    return this.find({ ...filter, deletedAt: null });
  };

  // Auto-exclude soft-deleted in finds
  schema.pre(/^find/, function(next) {
    if (!this.getQuery().includeDeleted) {
      this.where({ deletedAt: null });
    }
    next();
  });
}

// Usage
userSchema.plugin(softDeletePlugin);
```

### Global Plugins

```typescript
// Apply to all schemas
mongoose.plugin(function(schema: Schema) {
  schema.pre('save', function(next) {
    console.log(`Saving ${this.constructor.modelName}: ${this._id}`);
    next();
  });
});

// Timestamp plugin (built-in via { timestamps: true })
mongoose.plugin(require('mongoose-lean-virtuals'));
```

### Popular Plugins

```typescript
// mongoose-paginate-v2 — cursor/offset pagination
import mongoosePaginate from 'mongoose-paginate-v2';
userSchema.plugin(mongoosePaginate);
const result = await User.paginate({ role: 'user' }, { page: 2, limit: 20 });
// { docs, totalDocs, totalPages, page, limit, hasNextPage, hasPrevPage }

// mongoose-unique-validator — better unique error messages
import uniqueValidator from 'mongoose-unique-validator';
userSchema.plugin(uniqueValidator, { message: '{PATH} must be unique' });

// mongoose-autopopulate — auto-populate refs
import autopopulate from 'mongoose-autopopulate';
const postSchema = new Schema({
  author: { type: Schema.Types.ObjectId, ref: 'User', autopopulate: { select: 'name' } }
});
postSchema.plugin(autopopulate);
```

---

## Connection Management

### Connection Options

```typescript
import mongoose from 'mongoose';

await mongoose.connect('mongodb+srv://user:pass@cluster.mongodb.net/mydb', {
  // Connection pool
  maxPoolSize: 50,
  minPoolSize: 5,
  maxIdleTimeMS: 30000,

  // Timeouts
  serverSelectionTimeoutMS: 5000,
  connectTimeoutMS: 10000,
  socketTimeoutMS: 45000,

  // Write concern
  w: 'majority',
  retryWrites: true,

  // Read preference
  readPreference: 'secondaryPreferred',

  // Buffering (Mongoose-specific)
  bufferCommands: true,          // buffer ops until connected (default)
  autoIndex: false,              // don't auto-build indexes in production
  autoCreate: false,             // don't auto-create collections
});
```

### Multiple Connections

```typescript
// Main database
const mainConn = mongoose.createConnection('mongodb://localhost/main');
const User = mainConn.model('User', userSchema);

// Analytics database
const analyticsConn = mongoose.createConnection('mongodb://localhost/analytics');
const Event = analyticsConn.model('Event', eventSchema);

// Both connections managed independently
await mainConn.close();
await analyticsConn.close();
```

### Connection Events

```typescript
const conn = mongoose.connection;

conn.on('connected', () => console.log('MongoDB connected'));
conn.on('disconnected', () => console.log('MongoDB disconnected'));
conn.on('error', (err) => console.error('MongoDB error:', err));

// Graceful shutdown
async function gracefulShutdown(signal: string) {
  console.log(`${signal} received. Closing MongoDB connection...`);
  await mongoose.connection.close();
  process.exit(0);
}
process.on('SIGINT', () => gracefulShutdown('SIGINT'));
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));

// Reconnection is automatic with the Node.js driver
// Monitor with:
conn.on('reconnected', () => console.log('MongoDB reconnected'));
```

### Connection Pooling

```typescript
// Check pool status
const pool = mongoose.connection.getClient().topology;

// Monitor pool events (Node.js driver)
const client = mongoose.connection.getClient();
client.on('connectionPoolCreated', (event) => console.log('Pool created', event));
client.on('connectionCheckedOut', (event) => console.log('Connection used'));
client.on('connectionPoolCleared', (event) => console.warn('Pool cleared!'));

// Pool sizing for serverless/Lambda
await mongoose.connect(uri, {
  maxPoolSize: 1,       // Lambda: single connection per instance
  minPoolSize: 0,
  maxIdleTimeMS: 10000,
  serverSelectionTimeoutMS: 3000
});
```

---

## Migration Strategies

### Schema Versioning

```typescript
const userSchema = new Schema({
  schemaVersion: { type: Number, default: 2 },
  name: String,
  email: String,
  // v2: added address
  address: { street: String, city: String, zip: String }
});

// Middleware to migrate on read
userSchema.post('init', function(doc) {
  if (doc.schemaVersion === 1) {
    doc.address = doc.address || { street: '', city: '', zip: '' };
    doc.schemaVersion = 2;
    doc.save();
  }
});
```

### Using migrate-mongo

```bash
# Install
npm install -g migrate-mongo

# Initialize
migrate-mongo init

# Create migration
migrate-mongo create add-user-address
```

```javascript
// migrations/20240601-add-user-address.js
module.exports = {
  async up(db) {
    await db.collection('users').updateMany(
      { address: { $exists: false } },
      { $set: { address: { street: '', city: '', zip: '' }, schemaVersion: 2 } }
    );
    // Create index for new field
    await db.collection('users').createIndex({ 'address.zip': 1 });
  },

  async down(db) {
    await db.collection('users').updateMany(
      {},
      { $unset: { address: '' }, $set: { schemaVersion: 1 } }
    );
    await db.collection('users').dropIndex({ 'address.zip': 1 });
  }
};
```

```bash
# Run migrations
migrate-mongo up

# Rollback
migrate-mongo down
```

### Zero-Downtime Migrations

```typescript
// Strategy: expand-then-contract

// Phase 1: Expand — add new fields, keep old ones
// Deploy code that reads both old and new format
userSchema.pre('save', function(next) {
  // Write both formats during transition
  if (this.isModified('name') && !this.isModified('fullName')) {
    this.fullName = this.name;
  }
  next();
});

// Phase 2: Migrate — background job to update all documents
async function backgroundMigration() {
  const cursor = User.find({ fullName: { $exists: false } }).cursor();
  for await (const user of cursor) {
    user.fullName = user.name;
    await user.save();
  }
}

// Phase 3: Contract — remove old field, update code
// Deploy code that only uses new format
// Then remove old field with migration script
```

---

## TypeScript Integration

### Schema Type Inference

```typescript
import mongoose, { Schema, model, InferSchemaType, HydratedDocument } from 'mongoose';

// Define schema
const userSchema = new Schema({
  email: { type: String, required: true },
  name: { type: String, required: true },
  age: Number,
  role: { type: String, enum: ['user', 'admin'] as const, default: 'user' as const },
  tags: [String],
  profile: new Schema({
    bio: String,
    website: String
  })
});

// Infer types from schema (Mongoose 8+)
type IUser = InferSchemaType<typeof userSchema>;
// Equivalent to:
// { email: string; name: string; age?: number; role?: 'user' | 'admin'; ... }

// HydratedDocument includes Mongoose document methods
type UserDocument = HydratedDocument<IUser>;
```

### Typed Methods and Statics

```typescript
import { Model, Schema, model, HydratedDocument } from 'mongoose';

// Define interfaces
interface IUser {
  email: string;
  name: string;
  password: string;
  role: 'user' | 'admin';
}

interface IUserMethods {
  comparePassword(candidate: string): Promise<boolean>;
  isAdmin(): boolean;
}

interface UserModel extends Model<IUser, {}, IUserMethods> {
  findByEmail(email: string): Promise<HydratedDocument<IUser, IUserMethods> | null>;
  findAdmins(): Promise<HydratedDocument<IUser, IUserMethods>[]>;
}

// Create schema with types
const userSchema = new Schema<IUser, UserModel, IUserMethods>({
  email: { type: String, required: true, unique: true },
  name: { type: String, required: true },
  password: { type: String, required: true },
  role: { type: String, enum: ['user', 'admin'], default: 'user' }
});

userSchema.methods.comparePassword = async function(candidate: string) {
  return bcrypt.compare(candidate, this.password);
};

userSchema.methods.isAdmin = function() {
  return this.role === 'admin';
};

userSchema.statics.findByEmail = function(email: string) {
  return this.findOne({ email: email.toLowerCase() });
};

userSchema.statics.findAdmins = function() {
  return this.find({ role: 'admin' });
};

const User = model<IUser, UserModel>('User', userSchema);

// Fully typed
const user = await User.findByEmail('alice@example.com');
if (user) {
  const isMatch = await user.comparePassword('secret');  // typed
  console.log(user.isAdmin());                           // typed
}
```

### Typed Virtuals and Query Helpers

```typescript
import { Schema, model, Model, HydratedDocument, Query } from 'mongoose';

interface IUser {
  firstName: string;
  lastName: string;
  isActive: boolean;
  role: string;
}

interface IUserVirtuals {
  fullName: string;
}

interface IUserQueryHelpers {
  byRole(role: string): Query<any, HydratedDocument<IUser>, IUserQueryHelpers>;
  active(): Query<any, HydratedDocument<IUser>, IUserQueryHelpers>;
}

type UserModelType = Model<IUser, IUserQueryHelpers, {}, IUserVirtuals>;

const userSchema = new Schema<IUser, UserModelType, {}, IUserQueryHelpers, IUserVirtuals>({
  firstName: String,
  lastName: String,
  isActive: { type: Boolean, default: true },
  role: String
});

userSchema.virtual('fullName').get(function() {
  return `${this.firstName} ${this.lastName}`;
});

userSchema.query.byRole = function(role: string) {
  return this.where({ role });
};

userSchema.query.active = function() {
  return this.where({ isActive: true });
};

const User = model<IUser, UserModelType>('User', userSchema);

// Fully typed chain
const admins = await User.find().byRole('admin').active();
```

### Generic Document Type

```typescript
// Generic repository pattern with Mongoose + TypeScript
class BaseRepository<T> {
  constructor(private model: Model<T>) {}

  async findById(id: string): Promise<HydratedDocument<T> | null> {
    return this.model.findById(id);
  }

  async findAll(filter: Partial<T> = {}, options?: {
    limit?: number;
    skip?: number;
    sort?: Record<string, 1 | -1>;
  }): Promise<HydratedDocument<T>[]> {
    return this.model
      .find(filter as any)
      .limit(options?.limit ?? 50)
      .skip(options?.skip ?? 0)
      .sort(options?.sort ?? {});
  }

  async create(data: Partial<T>): Promise<HydratedDocument<T>> {
    return this.model.create(data);
  }

  async updateById(id: string, update: Partial<T>): Promise<HydratedDocument<T> | null> {
    return this.model.findByIdAndUpdate(id, update, { new: true, runValidators: true });
  }

  async deleteById(id: string): Promise<boolean> {
    const result = await this.model.deleteOne({ _id: id } as any);
    return result.deletedCount === 1;
  }
}

// Usage
const userRepo = new BaseRepository(User);
const user = await userRepo.findById('abc123');
```
