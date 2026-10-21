import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  images: {
    remotePatterns: [
      {
        protocol: "https",
        hostname: "jdduvyrrilnxlwbieqjr.supabase.co",
      },
    ],
  },
};

export default nextConfig;