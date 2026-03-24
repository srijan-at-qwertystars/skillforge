import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Enable standalone output for Docker deployment
  output: "standalone",

  // Image optimization
  images: {
    remotePatterns: [
      {
        protocol: "https",
        hostname: "cdn.example.com",
        pathname: "/images/**",
      },
      {
        protocol: "https",
        hostname: "avatars.githubusercontent.com",
      },
    ],
    formats: ["image/avif", "image/webp"],
    // Adjust for your deployment
    // deviceSizes: [640, 750, 828, 1080, 1200, 1920, 2048],
    // imageSizes: [16, 32, 48, 64, 96, 128, 256],
  },

  // Security headers
  async headers() {
    return [
      {
        source: "/(.*)",
        headers: [
          {
            key: "X-Frame-Options",
            value: "DENY",
          },
          {
            key: "X-Content-Type-Options",
            value: "nosniff",
          },
          {
            key: "Referrer-Policy",
            value: "strict-origin-when-cross-origin",
          },
          {
            key: "Permissions-Policy",
            value: "camera=(), microphone=(), geolocation=()",
          },
        ],
      },
      {
        // Cache static assets aggressively
        source: "/:all*(svg|jpg|jpeg|png|webp|avif|ico|woff2)",
        headers: [
          {
            key: "Cache-Control",
            value: "public, max-age=31536000, immutable",
          },
        ],
      },
    ];
  },

  // Redirects
  async redirects() {
    return [
      {
        source: "/old-blog/:slug",
        destination: "/blog/:slug",
        permanent: true, // 308
      },
      {
        source: "/docs",
        destination: "/docs/getting-started",
        permanent: false, // 307
      },
    ];
  },

  // Rewrites (URL stays the same, content from destination)
  async rewrites() {
    return {
      beforeFiles: [],
      afterFiles: [
        {
          source: "/api/proxy/:path*",
          destination: "https://api.backend.com/:path*",
        },
      ],
      fallback: [],
    };
  },

  // Logging for debugging fetch cache behavior
  logging: {
    fetches: {
      fullUrl: true,
    },
  },

  // Experimental features (opt in as needed)
  experimental: {
    // ppr: true,               // Partial Prerendering
    // reactCompiler: true,     // React Compiler (requires babel-plugin-react-compiler)
    // typedRoutes: true,       // Type-safe routes
  },

  // Webpack customization (if needed)
  // webpack: (config, { isServer }) => {
  //   if (!isServer) {
  //     config.resolve.fallback = { ...config.resolve.fallback, fs: false };
  //   }
  //   return config;
  // },

  // Environment variable validation at build
  env: {},

  // Strict mode for React (recommended)
  reactStrictMode: true,

  // Powered-by header removal
  poweredByHeader: false,
};

export default nextConfig;
