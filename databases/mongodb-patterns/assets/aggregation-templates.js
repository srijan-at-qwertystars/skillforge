// ============================================================================
// aggregation-templates.js — Common MongoDB Aggregation Pipeline Templates
// ============================================================================
// Ready-to-use pipeline templates for reporting, analytics, and ETL.
// Replace placeholders (COLLECTION, FIELD, etc.) with actual values.
//
// Usage:
//   Load in mongosh: load("aggregation-templates.js")
//   Or import in Node.js for reference
// ============================================================================

// ---------------------------------------------------------------------------
// REPORTING TEMPLATES
// ---------------------------------------------------------------------------

/**
 * Daily Revenue Report
 * Groups orders by day with revenue, order count, and average order value.
 */
const dailyRevenueReport = (startDate, endDate) => [
  { $match: {
    orderDate: { $gte: new Date(startDate), $lte: new Date(endDate) },
    status: { $in: ["completed", "shipped"] }
  }},
  { $group: {
    _id: { $dateToString: { format: "%Y-%m-%d", date: "$orderDate" } },
    revenue: { $sum: "$totalAmount" },
    orderCount: { $sum: 1 },
    avgOrderValue: { $avg: "$totalAmount" },
    uniqueCustomers: { $addToSet: "$customerId" }
  }},
  { $addFields: {
    uniqueCustomerCount: { $size: "$uniqueCustomers" }
  }},
  { $project: { uniqueCustomers: 0 } },
  { $sort: { _id: 1 } }
];

/**
 * Top N Products by Revenue
 * Ranks products by total revenue with quantity sold.
 */
const topProductsByRevenue = (n = 10) => [
  { $match: { status: "completed" } },
  { $unwind: "$items" },
  { $group: {
    _id: "$items.productId",
    productName: { $first: "$items.name" },
    totalRevenue: { $sum: { $multiply: ["$items.price", "$items.quantity"] } },
    totalQty: { $sum: "$items.quantity" },
    orderCount: { $sum: 1 }
  }},
  { $sort: { totalRevenue: -1 } },
  { $limit: n },
  { $setWindowFields: {
    sortBy: { totalRevenue: -1 },
    output: { rank: { $denseRank: {} } }
  }}
];

/**
 * Customer Cohort Analysis
 * Groups customers by signup month and tracks monthly activity.
 */
const customerCohortAnalysis = () => [
  { $group: {
    _id: "$customerId",
    firstOrder: { $min: "$orderDate" },
    orders: { $push: { date: "$orderDate", amount: "$totalAmount" } }
  }},
  { $addFields: {
    cohort: { $dateToString: { format: "%Y-%m", date: "$firstOrder" } }
  }},
  { $unwind: "$orders" },
  { $group: {
    _id: {
      cohort: "$cohort",
      activityMonth: { $dateToString: { format: "%Y-%m", date: "$orders.date" } }
    },
    customers: { $addToSet: "$_id" },
    revenue: { $sum: "$orders.amount" }
  }},
  { $addFields: {
    customerCount: { $size: "$customers" }
  }},
  { $project: { customers: 0 } },
  { $sort: { "_id.cohort": 1, "_id.activityMonth": 1 } }
];

/**
 * Multi-Facet Dashboard Summary
 * Produces overview stats, top categories, and recent trends in one query.
 */
const dashboardSummary = (days = 30) => [
  { $match: {
    orderDate: { $gte: new Date(Date.now() - days * 86400000) }
  }},
  { $facet: {
    overview: [
      { $group: {
        _id: null,
        totalRevenue: { $sum: "$totalAmount" },
        totalOrders: { $sum: 1 },
        avgOrderValue: { $avg: "$totalAmount" },
        uniqueCustomers: { $addToSet: "$customerId" }
      }},
      { $addFields: { uniqueCustomerCount: { $size: "$uniqueCustomers" } } },
      { $project: { _id: 0, uniqueCustomers: 0 } }
    ],
    topCategories: [
      { $unwind: "$items" },
      { $group: { _id: "$items.category", revenue: { $sum: "$items.price" }, count: { $sum: 1 } } },
      { $sort: { revenue: -1 } },
      { $limit: 5 }
    ],
    dailyTrend: [
      { $group: {
        _id: { $dateToString: { format: "%Y-%m-%d", date: "$orderDate" } },
        revenue: { $sum: "$totalAmount" },
        orders: { $sum: 1 }
      }},
      { $sort: { _id: 1 } }
    ]
  }}
];

// ---------------------------------------------------------------------------
// ANALYTICS TEMPLATES
// ---------------------------------------------------------------------------

/**
 * Funnel Analysis
 * Tracks conversion through stages: view → cart → checkout → purchase.
 */
const funnelAnalysis = (startDate, endDate) => [
  { $match: {
    timestamp: { $gte: new Date(startDate), $lte: new Date(endDate) }
  }},
  { $facet: {
    views:     [{ $match: { event: "product_view" } }, { $count: "count" }],
    addToCart: [{ $match: { event: "add_to_cart" } }, { $count: "count" }],
    checkout:  [{ $match: { event: "checkout_start" } }, { $count: "count" }],
    purchase:  [{ $match: { event: "purchase" } }, { $count: "count" }]
  }},
  { $project: {
    views:     { $arrayElemAt: ["$views.count", 0] },
    addToCart: { $arrayElemAt: ["$addToCart.count", 0] },
    checkout:  { $arrayElemAt: ["$checkout.count", 0] },
    purchase:  { $arrayElemAt: ["$purchase.count", 0] }
  }},
  { $addFields: {
    viewToCartRate:     { $round: [{ $multiply: [{ $divide: ["$addToCart", "$views"] }, 100] }, 1] },
    cartToCheckoutRate: { $round: [{ $multiply: [{ $divide: ["$checkout", "$addToCart"] }, 100] }, 1] },
    checkoutToPurchase: { $round: [{ $multiply: [{ $divide: ["$purchase", "$checkout"] }, 100] }, 1] },
    overallConversion:  { $round: [{ $multiply: [{ $divide: ["$purchase", "$views"] }, 100] }, 2] }
  }}
];

/**
 * Moving Average with Window Functions
 * Calculates 7-day and 30-day moving averages for a metric.
 */
const movingAverages = (metricField = "amount") => [
  { $group: {
    _id: { $dateToString: { format: "%Y-%m-%d", date: "$date" } },
    dailyTotal: { $sum: `$${metricField}` },
    count: { $sum: 1 }
  }},
  { $sort: { _id: 1 } },
  { $setWindowFields: {
    sortBy: { _id: 1 },
    output: {
      ma7: { $avg: "$dailyTotal", window: { documents: [-6, "current"] } },
      ma30: { $avg: "$dailyTotal", window: { documents: [-29, "current"] } },
      cumulativeTotal: { $sum: "$dailyTotal", window: { documents: ["unbounded", "current"] } }
    }
  }},
  { $addFields: {
    ma7: { $round: ["$ma7", 2] },
    ma30: { $round: ["$ma30", 2] }
  }}
];

/**
 * Percentile Distribution
 * Calculates p50, p90, p95, p99 for a metric grouped by category.
 */
const percentileDistribution = (groupField, metricField) => [
  { $group: {
    _id: `$${groupField}`,
    values: { $push: `$${metricField}` },
    count: { $sum: 1 },
    avg: { $avg: `$${metricField}` },
    min: { $min: `$${metricField}` },
    max: { $max: `$${metricField}` }
  }},
  { $addFields: {
    sortedValues: { $sortArray: { input: "$values", sortBy: 1 } }
  }},
  { $addFields: {
    p50: { $arrayElemAt: ["$sortedValues", { $floor: { $multiply: [0.50, "$count"] } }] },
    p90: { $arrayElemAt: ["$sortedValues", { $floor: { $multiply: [0.90, "$count"] } }] },
    p95: { $arrayElemAt: ["$sortedValues", { $floor: { $multiply: [0.95, "$count"] } }] },
    p99: { $arrayElemAt: ["$sortedValues", { $floor: { $multiply: [0.99, "$count"] } }] }
  }},
  { $project: { values: 0, sortedValues: 0 } },
  { $sort: { count: -1 } }
];

/**
 * Sessionization
 * Groups events into sessions with a 30-minute inactivity timeout.
 */
const sessionize = (inactivityMinutes = 30) => [
  { $sort: { userId: 1, timestamp: 1 } },
  { $setWindowFields: {
    partitionBy: "$userId",
    sortBy: { timestamp: 1 },
    output: {
      prevTimestamp: { $shift: { output: "$timestamp", by: -1 } }
    }
  }},
  { $addFields: {
    isNewSession: {
      $or: [
        { $eq: ["$prevTimestamp", null] },
        { $gt: [
          { $dateDiff: { startDate: "$prevTimestamp", endDate: "$timestamp", unit: "minute" } },
          inactivityMinutes
        ]}
      ]
    }
  }},
  { $setWindowFields: {
    partitionBy: "$userId",
    sortBy: { timestamp: 1 },
    output: {
      sessionId: {
        $sum: { $cond: ["$isNewSession", 1, 0] },
        window: { documents: ["unbounded", "current"] }
      }
    }
  }},
  { $group: {
    _id: { userId: "$userId", sessionId: "$sessionId" },
    startTime: { $min: "$timestamp" },
    endTime: { $max: "$timestamp" },
    events: { $push: { event: "$event", timestamp: "$timestamp" } },
    eventCount: { $sum: 1 }
  }},
  { $addFields: {
    durationMinutes: {
      $dateDiff: { startDate: "$startTime", endDate: "$endTime", unit: "minute" }
    }
  }}
];

// ---------------------------------------------------------------------------
// ETL TEMPLATES
// ---------------------------------------------------------------------------

/**
 * Flatten Nested Documents for Export
 * Converts nested/array data into flat rows suitable for CSV/data warehouse.
 */
const flattenForExport = () => [
  { $unwind: { path: "$items", preserveNullAndEmptyArrays: true } },
  { $lookup: {
    from: "customers",
    localField: "customerId",
    foreignField: "_id",
    as: "customer",
    pipeline: [{ $project: { name: 1, email: 1, segment: 1 } }]
  }},
  { $unwind: { path: "$customer", preserveNullAndEmptyArrays: true } },
  { $project: {
    _id: 0,
    orderId: "$_id",
    orderDate: 1,
    status: 1,
    customerName: "$customer.name",
    customerEmail: "$customer.email",
    customerSegment: "$customer.segment",
    productId: "$items.productId",
    productName: "$items.name",
    quantity: "$items.quantity",
    unitPrice: "$items.price",
    lineTotal: { $multiply: ["$items.quantity", "$items.price"] },
    totalAmount: 1
  }}
];

/**
 * Incremental ETL with $merge
 * Processes new/updated records and upserts into a summary collection.
 */
const incrementalETL = (lastRunDate) => [
  { $match: {
    updatedAt: { $gte: new Date(lastRunDate) }
  }},
  { $group: {
    _id: {
      customerId: "$customerId",
      month: { $dateToString: { format: "%Y-%m", date: "$orderDate" } }
    },
    totalSpent: { $sum: "$totalAmount" },
    orderCount: { $sum: 1 },
    avgOrder: { $avg: "$totalAmount" },
    lastOrder: { $max: "$orderDate" },
    products: { $addToSet: "$items.productId" }
  }},
  { $addFields: {
    uniqueProducts: { $size: { $reduce: {
      input: "$products",
      initialValue: [],
      in: { $setUnion: ["$$value", "$$this"] }
    }}}
  }},
  { $project: { products: 0 } },
  { $merge: {
    into: "customer_monthly_summary",
    on: "_id",
    whenMatched: [
      { $set: {
        totalSpent: { $add: ["$$ROOT.totalSpent", "$$new.totalSpent"] },
        orderCount: { $add: ["$$ROOT.orderCount", "$$new.orderCount"] },
        avgOrder: "$$new.avgOrder",
        lastOrder: { $max: ["$$ROOT.lastOrder", "$$new.lastOrder"] },
        uniqueProducts: "$$new.uniqueProducts",
        updatedAt: "$$NOW"
      }}
    ],
    whenNotMatched: "insert"
  }}
];

/**
 * Data Quality Report
 * Scans a collection for null fields, type mismatches, and outliers.
 */
const dataQualityReport = (fields) => [
  { $facet: {
    totalDocs: [{ $count: "count" }],
    ...Object.fromEntries(fields.map(f => [
      `${f}_nulls`,
      [
        { $match: { [f]: { $in: [null, "", undefined] } } },
        { $count: "count" }
      ]
    ])),
    ...Object.fromEntries(fields.filter(f => f !== '_id').map(f => [
      `${f}_types`,
      [
        { $group: { _id: { $type: `$${f}` }, count: { $sum: 1 } } }
      ]
    ]))
  }}
];

/**
 * Change Data Capture summary
 * Summarizes changes from a change events collection for downstream sync.
 */
const cdcSummary = (sinceDate) => [
  { $match: { timestamp: { $gte: new Date(sinceDate) } } },
  { $group: {
    _id: {
      collection: "$ns.coll",
      operation: "$operationType"
    },
    count: { $sum: 1 },
    firstChange: { $min: "$timestamp" },
    lastChange: { $max: "$timestamp" }
  }},
  { $group: {
    _id: "$_id.collection",
    operations: {
      $push: {
        op: "$_id.operation",
        count: "$count",
        first: "$firstChange",
        last: "$lastChange"
      }
    },
    totalChanges: { $sum: "$count" }
  }},
  { $sort: { totalChanges: -1 } }
];

// Export for Node.js usage
if (typeof module !== "undefined") {
  module.exports = {
    dailyRevenueReport,
    topProductsByRevenue,
    customerCohortAnalysis,
    dashboardSummary,
    funnelAnalysis,
    movingAverages,
    percentileDistribution,
    sessionize,
    flattenForExport,
    incrementalETL,
    dataQualityReport,
    cdcSummary,
  };
}
