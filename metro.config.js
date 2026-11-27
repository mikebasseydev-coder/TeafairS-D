const path = require("path");
const { getDefaultConfig } = require("expo/metro-config");
const { withNativeWind } = require("nativewind/metro");

const config = getDefaultConfig(__dirname);

// The Supabase side is Deno and never part of the app bundle.
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
config.resolver.blockList = [new RegExp(`^${escape(path.join(__dirname, "supabase"))}[\\\\/].*`)];

module.exports = withNativeWind(config, { input: "./global.css" });
