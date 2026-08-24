import { create } from 'zustand';

interface AggregatorState {}

export const useAggregatorStore = create<AggregatorState>(() => ({}));
