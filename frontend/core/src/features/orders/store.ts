import { create } from 'zustand';

interface OrdersState {}

export const useOrdersStore = create<OrdersState>(() => ({}));
