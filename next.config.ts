import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  images: {
    remotePatterns: [
      {
        protocol: "https",
        hostname: "jdduvyrrilnxlwbieqjr.supabase.co", // O endereço exato do seu erro
      },
    ],
  },
};

export default nextConfig;