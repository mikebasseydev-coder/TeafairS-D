import { create } from 'zustand';

interface CatalogState {}

export const useCatalogStore = create<CatalogState>(() => ({}));
