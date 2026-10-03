/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'export',
  // GitHub Pages serves this site at https://ykstorm.github.io/stackup/, so
  // every route and every /_next asset needs the /stackup prefix. Internal
  // links use next/link, which adds it.
  basePath: '/stackup',
  images: { unoptimized: true },
  trailingSlash: true,
};

export default nextConfig;
