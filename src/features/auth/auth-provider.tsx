import { useQueryClient } from "@tanstack/react-query";
import type { Session, User } from "@supabase/supabase-js";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";

import { isSupabaseConfigured } from "@/lib/env";
import { supabase } from "@/lib/supabase/client";

interface AuthState {
  /** true until the initial session lookup settles. */
  loading: boolean;
  configured: boolean;
  session: Session | null;
  user: User | null;
  signIn: (email: string, password: string) => Promise<void>;
  signUp: (
    email: string,
    password: string,
  ) => Promise<{ needsEmailConfirmation: boolean }>;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(isSupabaseConfigured);
  const queryClient = useQueryClient();
  const knownUserId = useRef<string | null>(null);

  useEffect(() => {
    if (!supabase) return;
    const client = supabase;

    const { data: subscription } = client.auth.onAuthStateChange(
      (event, nextSession) => {
        const nextUserId = nextSession?.user.id ?? null;
        // Cached orders, addresses and profiles belong to one customer. Drop them on
        // sign-out, and also if the signed-in user changes without a sign-out event.
        const userChanged =
          knownUserId.current !== null && nextUserId !== knownUserId.current;
        if (event === "SIGNED_OUT" || userChanged) queryClient.clear();
        knownUserId.current = nextUserId;

        setSession(nextSession);
        setLoading(false);
      },
    );

    void client.auth.getSession().then(({ data }) => {
      knownUserId.current = data.session?.user.id ?? knownUserId.current;
      setSession(data.session);
      setLoading(false);
    });

    return () => subscription.subscription.unsubscribe();
  }, [queryClient]);

  const signIn = useCallback(async (email: string, password: string) => {
    if (!supabase) throw new Error("Supabase is not configured.");
    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });
    if (error) throw new Error(error.message);
  }, []);

  const signUp = useCallback(async (email: string, password: string) => {
    if (!supabase) throw new Error("Supabase is not configured.");
    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: { emailRedirectTo: window.location.origin },
    });
    if (error) throw new Error(error.message);
    return { needsEmailConfirmation: data.session === null };
  }, []);

  const signOut = useCallback(async () => {
    if (!supabase) return;
    await supabase.auth.signOut();
  }, []);

  const value = useMemo<AuthState>(
    () => ({
      loading,
      configured: isSupabaseConfigured,
      session,
      user: session?.user ?? null,
      signIn,
      signUp,
      signOut,
    }),
    [loading, session, signIn, signUp, signOut],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const context = useContext(AuthContext);
  if (!context) throw new Error("useAuth must be used inside <AuthProvider>.");
  return context;
}
