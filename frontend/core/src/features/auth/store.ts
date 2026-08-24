import { create } from 'zustand';

interface AuthState {}

export const useAuthStore = create<AuthState>(() => ({}));
