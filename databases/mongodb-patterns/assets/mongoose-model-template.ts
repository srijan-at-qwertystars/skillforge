// ============================================================================
// mongoose-model-template.ts — Full-Featured Mongoose Model (TypeScript)
// ============================================================================
// Demonstrates all Mongoose patterns: types, virtuals, methods, statics,
// middleware, query helpers, plugins, indexes, and TypeScript integration.
//
// Usage:
//   Copy and adapt for your models. Requires:
//     npm install mongoose
//     npm install -D @types/mongoose (Mongoose 6) or bundled types (Mongoose 7/8)
// ============================================================================

import mongoose, {
  Schema,
  model,
  Model,
  HydratedDocument,
  Query,
  Types,
  CallbackError,
} from "mongoose";

// ---------------------------------------------------------------------------
// 1. Interface Definitions
// ---------------------------------------------------------------------------

/** Base document fields */
interface IUser {
  email: string;
  password: string;
  name: {
    first: string;
    last: string;
  };
  role: "user" | "admin" | "moderator";
  status: "active" | "inactive" | "suspended";
  profile: {
    bio?: string;
    avatar?: string;
    website?: string;
    socialLinks?: Map<string, string>;
  };
  tags: string[];
  loginAttempts: number;
  lockUntil?: Date;
  lastLoginAt?: Date;
  preferences: {
    newsletter: boolean;
    language: string;
    timezone: string;
  };
  metadata?: Record<string, unknown>;
}

/** Virtual fields */
interface IUserVirtuals {
  fullName: string;
  isLocked: boolean;
  profileUrl: string;
}

/** Instance methods */
interface IUserMethods {
  comparePassword(candidate: string): Promise<boolean>;
  incrementLoginAttempts(): Promise<void>;
  resetLoginAttempts(): Promise<void>;
  toPublicJSON(): Partial<IUser & IUserVirtuals>;
}

/** Query helpers */
interface IUserQueryHelpers {
  byRole(role: string): Query<any, HydratedDocument<IUser>, IUserQueryHelpers>;
  active(): Query<any, HydratedDocument<IUser>, IUserQueryHelpers>;
  search(term: string): Query<any, HydratedDocument<IUser>, IUserQueryHelpers>;
}

/** Static methods on the model */
interface IUserModel
  extends Model<IUser, IUserQueryHelpers, IUserMethods, IUserVirtuals> {
  findByEmail(
    email: string
  ): Promise<HydratedDocument<IUser, IUserMethods & IUserVirtuals> | null>;
  findAdmins(): Promise<HydratedDocument<IUser, IUserMethods & IUserVirtuals>[]>;
  getStats(): Promise<Array<{ _id: string; count: number }>>;
}

/** Typed document */
type UserDocument = HydratedDocument<IUser, IUserMethods & IUserVirtuals>;

// ---------------------------------------------------------------------------
// 2. Schema Definition
// ---------------------------------------------------------------------------

const userSchema = new Schema<
  IUser,
  IUserModel,
  IUserMethods,
  IUserQueryHelpers,
  IUserVirtuals
>(
  {
    email: {
      type: String,
      required: [true, "Email is required"],
      unique: true,
      lowercase: true,
      trim: true,
      validate: {
        validator: (v: string) => /^[\w.-]+@[\w.-]+\.\w{2,}$/.test(v),
        message: (props) => `${props.value} is not a valid email`,
      },
    },
    password: {
      type: String,
      required: [true, "Password is required"],
      minlength: [8, "Password must be at least 8 characters"],
      select: false, // excluded from queries by default
    },
    name: {
      first: { type: String, required: true, trim: true, maxlength: 50 },
      last: { type: String, required: true, trim: true, maxlength: 50 },
    },
    role: {
      type: String,
      enum: {
        values: ["user", "admin", "moderator"],
        message: "{VALUE} is not a valid role",
      },
      default: "user",
    },
    status: {
      type: String,
      enum: ["active", "inactive", "suspended"],
      default: "active",
    },
    profile: {
      bio: { type: String, maxlength: 500 },
      avatar: String,
      website: {
        type: String,
        validate: {
          validator: (v: string) =>
            !v || /^https?:\/\/.+\..+/.test(v),
          message: "Invalid URL format",
        },
      },
      socialLinks: { type: Map, of: String },
    },
    tags: [{ type: String, lowercase: true, trim: true }],
    loginAttempts: { type: Number, default: 0 },
    lockUntil: Date,
    lastLoginAt: Date,
    preferences: {
      newsletter: { type: Boolean, default: false },
      language: { type: String, default: "en", enum: ["en", "es", "fr", "de", "ja"] },
      timezone: { type: String, default: "UTC" },
    },
    metadata: { type: Schema.Types.Mixed },
  },
  {
    timestamps: true, // createdAt, updatedAt
    collection: "users",
    toJSON: { virtuals: true, transform: (_doc, ret) => { delete ret.__v; return ret; } },
    toObject: { virtuals: true },
    optimisticConcurrency: true,
  }
);

// ---------------------------------------------------------------------------
// 3. Indexes
// ---------------------------------------------------------------------------

userSchema.index({ email: 1 }, { unique: true });
userSchema.index({ role: 1, status: 1 });
userSchema.index({ "name.last": 1, "name.first": 1 });
userSchema.index({ tags: 1 });
userSchema.index(
  { createdAt: 1 },
  { expireAfterSeconds: 86400 * 365, partialFilterExpression: { status: "inactive" } }
);

// ---------------------------------------------------------------------------
// 4. Virtuals
// ---------------------------------------------------------------------------

userSchema.virtual("fullName")
  .get(function (this: IUser) {
    return `${this.name.first} ${this.name.last}`;
  })
  .set(function (this: IUser, fullName: string) {
    const [first, ...rest] = fullName.split(" ");
    this.name.first = first;
    this.name.last = rest.join(" ");
  });

userSchema.virtual("isLocked").get(function (this: IUser) {
  return !!(this.lockUntil && this.lockUntil > new Date());
});

userSchema.virtual("profileUrl").get(function (this: IUser & { _id: Types.ObjectId }) {
  return `/users/${this._id}`;
});

// Virtual populate — user's posts (no foreign key on User)
userSchema.virtual("posts", {
  ref: "Post",
  localField: "_id",
  foreignField: "authorId",
  options: { sort: { createdAt: -1 }, limit: 10 },
});

// ---------------------------------------------------------------------------
// 5. Instance Methods
// ---------------------------------------------------------------------------

userSchema.methods.comparePassword = async function (
  this: UserDocument,
  candidate: string
): Promise<boolean> {
  // In production, use bcrypt:
  // return bcrypt.compare(candidate, this.password);
  return candidate === this.password; // placeholder
};

userSchema.methods.incrementLoginAttempts = async function (
  this: UserDocument
): Promise<void> {
  // Reset if lock has expired
  if (this.lockUntil && this.lockUntil < new Date()) {
    await this.updateOne({
      $set: { loginAttempts: 1 },
      $unset: { lockUntil: 1 },
    });
    return;
  }

  const updates: Record<string, any> = { $inc: { loginAttempts: 1 } };
  // Lock after 5 failed attempts for 2 hours
  if (this.loginAttempts + 1 >= 5) {
    updates.$set = { lockUntil: new Date(Date.now() + 2 * 60 * 60 * 1000) };
  }
  await this.updateOne(updates);
};

userSchema.methods.resetLoginAttempts = async function (
  this: UserDocument
): Promise<void> {
  await this.updateOne({
    $set: { loginAttempts: 0, lastLoginAt: new Date() },
    $unset: { lockUntil: 1 },
  });
};

userSchema.methods.toPublicJSON = function (this: UserDocument) {
  return {
    email: this.email,
    name: this.name,
    role: this.role,
    profile: this.profile,
    tags: this.tags,
  };
};

// ---------------------------------------------------------------------------
// 6. Static Methods
// ---------------------------------------------------------------------------

userSchema.statics.findByEmail = function (email: string) {
  return this.findOne({ email: email.toLowerCase() });
};

userSchema.statics.findAdmins = function () {
  return this.find({ role: "admin", status: "active" }).sort({ "name.last": 1 });
};

userSchema.statics.getStats = function () {
  return this.aggregate([
    { $match: { status: "active" } },
    {
      $group: {
        _id: "$role",
        count: { $sum: 1 },
      },
    },
    { $sort: { count: -1 } },
  ]);
};

// ---------------------------------------------------------------------------
// 7. Query Helpers
// ---------------------------------------------------------------------------

userSchema.query.byRole = function (
  this: Query<any, UserDocument, IUserQueryHelpers>,
  role: string
) {
  return this.where({ role });
};

userSchema.query.active = function (
  this: Query<any, UserDocument, IUserQueryHelpers>
) {
  return this.where({ status: "active" });
};

userSchema.query.search = function (
  this: Query<any, UserDocument, IUserQueryHelpers>,
  term: string
) {
  const regex = new RegExp(term, "i");
  return this.where({
    $or: [
      { email: regex },
      { "name.first": regex },
      { "name.last": regex },
      { tags: regex },
    ],
  });
};

// ---------------------------------------------------------------------------
// 8. Middleware (Hooks)
// ---------------------------------------------------------------------------

// Hash password before save
userSchema.pre("save", async function (next) {
  if (!this.isModified("password")) return next();
  // In production: this.password = await bcrypt.hash(this.password, 12);
  next();
});

// Normalize tags
userSchema.pre("save", function (next) {
  if (this.isModified("tags")) {
    this.tags = [...new Set(this.tags)]; // deduplicate
  }
  next();
});

// Auto-filter soft-deleted/suspended (customize as needed)
userSchema.pre(/^find/, function (this: any, next) {
  // Only apply if not explicitly querying for suspended users
  if (!this.getQuery().status) {
    this.where({ status: { $ne: "suspended" } });
  }
  next();
});

// Post-save: log creation
userSchema.post("save", function (doc) {
  if (doc.isNew !== false) {
    console.log(`[User] Created: ${doc.email}`);
  }
});

// Error handling middleware for duplicate key
userSchema.post(
  "save",
  function (error: any, _doc: any, next: (err?: CallbackError) => void) {
    if (error.name === "MongoServerError" && error.code === 11000) {
      next(new Error("Email already exists") as CallbackError);
    } else {
      next(error);
    }
  }
);

// ---------------------------------------------------------------------------
// 9. Model Export
// ---------------------------------------------------------------------------

const User = model<IUser, IUserModel>("User", userSchema);

export { User, IUser, UserDocument, IUserMethods, IUserModel };
export default User;

// ---------------------------------------------------------------------------
// 10. Usage Examples
// ---------------------------------------------------------------------------

/*
// Create
const user = await User.create({
  email: "alice@example.com",
  password: "securepass123",
  name: { first: "Alice", last: "Smith" },
  tags: ["developer", "typescript"],
});

// Find with query helpers
const admins = await User.find().byRole("admin").active();

// Search
const results = await User.find().search("alice").active();

// Statics
const stats = await User.getStats();
const admin = await User.findByEmail("admin@example.com");

// Instance methods
const isMatch = await user.comparePassword("securepass123");

// Virtuals
console.log(user.fullName);    // "Alice Smith"
console.log(user.isLocked);    // false
console.log(user.profileUrl);  // "/users/..."

// Lean query (plain objects, faster)
const users = await User.find().active().lean();

// Populate virtual
const userWithPosts = await User.findById(id).populate("posts");

// Transaction
const session = await mongoose.startSession();
await session.withTransaction(async () => {
  await User.create([{ ... }], { session });
  await OtherModel.updateOne({ ... }, { ... }, { session });
});
await session.endSession();
*/
