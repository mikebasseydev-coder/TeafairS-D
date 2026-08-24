import { Storage } from './types';

class MemoryStorage implements Storage {
  private data = new Map<string, string>();

  async getItem(key: string): Promise<string | null> {
    return this.data.has(key) ? this.data.get(key)! : null;
  }

  async setItem(key: string, value: string): Promise<void> {
    this.data.set(key, value);
  }

  async removeItem(key: string): Promise<void> {
    this.data.delete(key);
  }
}

describe('Storage interface', () => {
  it('round-trips a value through set/get/remove', async () => {
    const storage: Storage = new MemoryStorage();

    expect(await storage.getItem('token')).toBeNull();

    await storage.setItem('token', 'abc123');
    expect(await storage.getItem('token')).toBe('abc123');

    await storage.removeItem('token');
    expect(await storage.getItem('token')).toBeNull();
  });
});
