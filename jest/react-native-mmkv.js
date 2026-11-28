// Jest stand-in for react-native-mmkv (a native Nitro module): one in-memory
// map per instance id. Unit tests only; the app uses the real module.
const instances = new Map();
function createMMKV({ id = "mmkv.default" } = {}) {
  if (!instances.has(id)) instances.set(id, new Map());
  const m = instances.get(id);
  return {
    getString: (k) => m.get(k),
    set: (k, v) => void m.set(k, String(v)),
    remove: (k) => m.delete(k),
    clearAll: () => m.clear(),
    getAllKeys: () => [...m.keys()],
  };
}
module.exports = { createMMKV };
