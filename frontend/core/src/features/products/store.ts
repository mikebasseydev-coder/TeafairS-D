import { create } from 'zustand';

interface ProductsState {}

export const useProductsStore = create<ProductsState>(() => ({}));
